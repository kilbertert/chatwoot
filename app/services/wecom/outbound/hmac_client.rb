# Chatwoot → wecom-ai 调用的 HMAC 客户端
# 用 channel.wecom_ai_secret 给请求 body 计算 HMAC-SHA256, 作为 X-WecomAI-Signature 头
class Wecom::Outbound::HmacClient
  TIMEOUT = 15

  def initialize(channel)
    @channel = channel
    @base_url = channel.wecom_ai_service_url.to_s.chomp('/')
  end

  def post(path, payload)
    body = payload.is_a?(String) ? payload : payload.to_json
    signature = sign(body)
    Rails.logger.debug("[Wecom::HmacClient] POST #{@base_url}#{path} body_size=#{body.bytesize}")

    response = http_client.post(
      "#{@base_url}#{path}",
      body,
      {
        'Content-Type' => 'application/json',
        'X-WecomAI-Signature' => signature
      }
    )

    parse_response(response)
  rescue StandardError => e
    Rails.logger.error("[Wecom::HmacClient] post error: #{e.class.name}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    raise
  end

  private

  def sign(body)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), @channel.wecom_ai_secret, body)
  end

  def http_client
    @http_client ||= Faraday.new do |f|
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end

  def parse_response(response)
    # 兼容 Faraday middleware 不同解析 (可能是 String / Hash / Array)
    body_str =
      case response.body
      when String then response.body
      when Hash, Array then response.body.to_json
      else response.body.to_s
      end

    parsed = {}
    if body_str.is_a?(String) && !body_str.empty? && body_str.start_with?('{', '[')
      begin
        parsed = JSON.parse(body_str)
      rescue JSON::ParserError
        parsed = {}
      end
    end
    parsed = {} unless parsed.is_a?(Hash)  # 防止上游返回 [..] 时被当作 hash

    raw_error = parsed['error'] || parsed['errmsg'] || (response.success? ? nil : "HTTP #{response.status}")
    safe_error = raw_error.is_a?(String) ? raw_error : raw_error.to_s

    {
      success: response.status >= 200 && response.status < 300,
      status: response.status,
      body: parsed,
      error: safe_error,
      msgid: parsed['msgid']
    }
  end
end
