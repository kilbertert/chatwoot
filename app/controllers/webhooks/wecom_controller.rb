class Webhooks::WecomController < ActionController::API
  def process_payload
    raw_body = request.raw_post
    return head :bad_request if raw_body.blank?

    body_params = parse_body(raw_body)
    return head :bad_request if body_params.blank?
    return head :unauthorized unless valid_signature?(raw_body)

    Webhooks::WecomEventsJob.perform_later(
      params: body_params,
      open_kfid: params[:open_kfid],
      post_body: raw_body,
      signature: provided_signature,
      trigger_bot_handoff: body_params['reason'] == 'ai_handoff'
    )
    head :ok
  end

  private

  def parse_body(raw_body)
    parsed = JSON.parse(raw_body)
    parsed if parsed.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end

  def valid_signature?(raw_body)
    return false if provided_signature.blank?

    channel = Channel::Wecom.find_by(open_kfid: params[:open_kfid])
    return false if channel.nil? || channel.wecom_ai_secret.blank?
    return false if channel.account_id.nil? || !channel.account&.active?

    expected = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), channel.wecom_ai_secret, raw_body)
    ActiveSupport::SecurityUtils.secure_compare(expected, provided_signature)
  end

  def provided_signature
    request.headers['X-WecomAI-Signature'].to_s
  end
end
