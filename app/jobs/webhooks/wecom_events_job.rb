# 处理 wecom-ai 推送的入站事件
# 鉴权: HMAC-SHA256(post_body, channel.wecom_ai_secret) 头取自 X-WecomAI-Signature
class Webhooks::WecomEventsJob < MutexApplicationJob
  queue_as :low
  retry_on ActiveRecord::Deadlocked, wait: 3.seconds, attempts: 3
  retry_on_lock_conflict wait: ->(executions) { executions.seconds }, attempts: 3, on_exhaustion: :process_without_lock

  def perform(params: {}, open_kfid: '', post_body: '', signature: '', trigger_bot_handoff: false)
    assign_job_attributes(
      params: params,
      open_kfid: open_kfid,
      post_body: post_body,
      signature: signature,
      trigger_bot_handoff: trigger_bot_handoff
    )

    return unless valid_channel?
    return unless valid_post_body?

    if @trigger_bot_handoff
      handle_bot_handoff!
    else
      process_message_with_lock
    end
  end

  def process_without_lock(*args, **kwargs)
    assign_job_attributes_from(kwargs.presence || args.first || {})

    return unless valid_channel?
    return unless valid_post_body?
    return handle_bot_handoff! if @trigger_bot_handoff

    Rails.logger.warn("[#{self.class.name}] Processing without lock after lock retry exhaustion")
    process_message
  end

  def handle_bot_handoff!
    # 触发 Conversation#bot_handoff! - 不创建 message
    contact_inbox = @channel.inbox.contact_inboxes.find_by(source_id: @params[:external_userid])
    return unless contact_inbox

    # E5: 跳过 resolved 会话 (已解决这轮不再触发 handoff)
    conversation = contact_inbox.conversations.where.not(status: :resolved).last
    return unless conversation

    conversation.bot_handoff!  # 触发 CONVERSATION_BOT_HANDOFF dispatcher 事件
  end

  def process_message_with_lock
    return process_message if @params[:external_userid].blank?

    with_lock(wecom_message_mutex_key, 5.seconds) do
      process_message
    end
  end

  def process_message
    Wecom::IncomingMessageService.new(inbox: @channel.inbox, params: @params.with_indifferent_access).perform
  end

  def wecom_message_mutex_key
    format(
      ::Redis::Alfred::WECOM_MESSAGE_MUTEX,
      inbox_id: @channel.inbox.id,
      external_userid: @params[:external_userid]
    )
  end

  private

  def assign_job_attributes_from(attributes)
    assign_job_attributes(**attributes.symbolize_keys.slice(:params, :open_kfid, :post_body, :signature, :trigger_bot_handoff))
  end

  def assign_job_attributes(params: {}, open_kfid: '', post_body: '', signature: '', trigger_bot_handoff: false)
    @params = params.with_indifferent_access
    @open_kfid = open_kfid
    @post_body = post_body
    @signature = signature
    @trigger_bot_handoff = trigger_bot_handoff
  end

  def valid_post_body?
    return false if @post_body.blank? || @signature.blank?
    return false if @channel.wecom_ai_secret.blank?

    expected = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), @channel.wecom_ai_secret, @post_body)
    ActiveSupport::SecurityUtils.secure_compare(expected, @signature.to_s)
  end

  def valid_channel?
    @channel = Channel::Wecom.find_by(open_kfid: @open_kfid)
    return false if @channel.nil?
    return false if @channel.account_id.nil?
    return false unless @channel.account&.active?

    true
  end
end
