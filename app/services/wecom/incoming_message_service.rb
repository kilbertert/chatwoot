# 处理 wecom-ai 通过 /webhooks/wecom/:open_kfid 推送的入站消息
# wecom-ai 负责 WeCom 协议解析 (AES / SHA1 / 媒体下载), 此 service 只把
# 已规范化的消息落地为 Chatwoot 的 Contact / ContactInbox / Conversation / Message
class Wecom::IncomingMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if unsupported_event?

    return if already_processed?

    set_contact
    set_conversation
    set_sender_contact if group_chat?

    create_message
    attach_files if attachment_required?

    @message.save!
  end

  private

  def unsupported_event?
    params[:message].blank? || params[:external_userid].blank?
  end

  def already_processed?
    msgid = params.dig(:message, :msgid).to_s
    return false if msgid.blank?

    @inbox.messages.where(source_id: msgid).exists?
  end

  def set_contact
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: params[:external_userid],
      inbox: @inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def set_conversation
    @conversation = if @inbox.lock_to_single_conversation?
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.create!(
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    )
  end

  def create_message
    @message = @conversation.messages.build(
      content: message_content,
      account_id: @inbox.account_id,
      content_type: 'text',
      inbox_id: @inbox.id,
      **message_attrs,
      source_id: params.dig(:message, :msgid).to_s
    )
  end

  # origin: 1 = 客户发送 (默认), 2 = AI/agentbot 回复
  # origin=2 时 message_type=outgoing, sender=inbox 的 agent_bot (不在则 fallback contact)
  def message_attrs
    origin = params.dig(:message, :origin).to_i
    if origin == 2
      { message_type: :outgoing, sender: outgoing_sender }
    else
      # 群聊方案 B: 用 per-user Contact 作 sender, 让 agent 看到具体谁发的;
      # 单聊或无 per-user 时 fallback @contact (group-level)
      { message_type: :incoming, sender: @sender_contact || @contact }
    end
  end


  # 方案 B: 群聊合并 conversation, 但 message.sender 按 user 区分
  # 找/建 per-user Contact (按 social_wecom_user_id), 不创建 ContactInbox
  def set_sender_contact
    userid = params.dig(:contact, :userid).presence
    return if userid.blank?

    user_name = params.dig(:contact, :user_name).presence
    @sender_contact = ::Contact.find_by(
      account_id: @inbox.account_id,
      additional_attributes: { social_wecom_user_id: userid }
    )
    return if @sender_contact.present?

    @sender_contact = ::Contact.create!(
      account_id: @inbox.account_id,
      name: user_name.presence || "WeCom User #{userid}",
      additional_attributes: { social_wecom_user_id: userid }
    )
  end

  def group_chat?
    params.dig(:contact, :chat_type) == "group"
  end
  def outgoing_sender
    @inbox.agent_bot || @inbox.account.agent_bots.first || @contact
  end

  def message_content
    case params.dig(:message, :msgtype)
    when 'text'      then params.dig(:message, :text, :content)
    when 'image'     then params.dig(:message, :image, :caption) || '[图片]'
    when 'voice'     then '[语音]'
    when 'video'     then '[视频]'
    when 'file'      then "[文件] #{params.dig(:message, :file, :filename).to_s}"
    else                  '[不支持的消息类型]'
    end
  end

  def attachment_required?
    %w[image voice video file].include?(params.dig(:message, :msgtype).to_s)
  end

  def attach_files
    return unless attachment_required?

    # Sprint 3: 8501 把下完的 bytes base64 后塞在 message_data[:chatwoot_attachment]
    # 格式: { base64:, content_type:, filename:, size: }
    attachment = params.dig(:message, :chatwoot_attachment)
    return if attachment.blank?

    base64_data = attachment[:base64]
    return if base64_data.blank?

    decoded = Base64.decode64(base64_data)
    filename = attachment[:filename].presence || "#{params.dig(:message, :msgtype)}_#{SecureRandom.hex(4)}.bin"
    content_type = attachment[:content_type].presence || 'application/octet-stream'

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_type_for_msgtype,
      file: {
        io: StringIO.new(decoded),
        filename: filename,
        content_type: content_type
      }
    )
  end

  def file_type_for_msgtype
    case params.dig(:message, :msgtype)
    when 'image' then :image
    when 'voice' then :audio
    when 'video' then :video
    when 'file'  then :file
    else :file
    end
  end

  def contact_attributes
    {
      name: params.dig(:contact, :name).presence || Haikunator.haikunate(1000),
      avatar_url: params.dig(:contact, :avatar),
      additional_attributes: {
        social_wecom_user_id: (params.dig(:contact, :userid).presence || params[:external_userid]),
        social_wecom_chat_id: params.dig(:contact, :chat_id).presence,
        social_wecom_chat_type: params.dig(:contact, :chat_type).presence,
      }
    }
  end
end
