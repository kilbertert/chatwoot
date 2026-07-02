# frozen_string_literal: true

# Sprint 2: 公共查询端点 - wecom-ai 在调 Dify 前调本端点查 handoff 状态
#
# 路由: GET /public/api/v1/wecom/handoff_status?open_kfid=X&external_userid=Y
# 鉴权 (E1): HMAC-SHA256(query_string, channel.wecom_ai_secret) 头取自
# X-WecomAI-Signature。wecom-ai 侧 ChatwootSyncService.check_handoff 用
# urllib.parse.urlencode({"open_kfid":..,"external_userid":..}) 生成 query string
# 并签名, 本端必须用原始 request.query_string 验签 (不能重组 params, 否则参数
# 顺序/编码不一致 → 签名不匹配 → 每条 KF 消息 handoff 查询 401 → 永远走 AI)。
# secret 复用 per-channel wecom_ai_secret (与 webhook 路径一致; Python 侧全局
# hmac_secret 假设与各 channel secret 一致)。
class Public::Api::V1::Wecom::HandoffStatusesController < PublicController
  def show
    return render_unauthorized unless valid_signature?

    open_kfid = params[:open_kfid]
    external_userid = params[:external_userid]

    if open_kfid.blank? || external_userid.blank?
      return render json: { error: 'open_kfid and external_userid required' }, status: 422
    end

    result = Wecom::HandoffQueryService.new(
      open_kfid: open_kfid,
      external_userid: external_userid
    ).perform

    # 4xx errors (channel_not_found / inbox_not_found) — 404; 其他 (handoff:false) 200
    status = if %w[channel_not_found inbox_not_found].include?(result[:reason])
               404
             else
               200
             end

    render json: result, status: status
  end

  private

  # 验签: 用 open_kfid 定位 channel, 取其 wecom_ai_secret 对原始 query_string 算
  # HMAC-SHA256, 与 X-WecomAI-Signature 头 secure_compare。
  def valid_signature?
    provided = request.headers['X-WecomAI-Signature'].to_s
    return false if provided.blank?

    channel = Channel::Wecom.find_by(open_kfid: params[:open_kfid])
    return false if channel.nil? || channel.wecom_ai_secret.blank?

    expected = OpenSSL::HMAC.hexdigest(
      OpenSSL::Digest.new('SHA256'), channel.wecom_ai_secret, request.query_string
    )
    ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  def render_unauthorized
    render json: { error: 'invalid signature' }, status: :unauthorized
  end
end
