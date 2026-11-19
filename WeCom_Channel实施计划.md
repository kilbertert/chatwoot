Chatwoot 新增企业微信 (WeCom) Channel — 实施计划

Context

用户已经在 /home/ranlei/wecom-ai-customer-service/ 有一个完整可运行的 FastAPI 服务，它处理企业微信客服 (/wechat/kf/callback) 和智能机器人 (/wechat/bot/callback) 的回调，调用 Coze/Dify 生成 AI
回复，再通过企业微信客服消息接口回给用户。这套实现没有人类坐席——AI 是唯一的回复者。

问题：用户想把企业微信接入 Chatwoot 的客服工作台，让人类坐席可以接管或协作 AI 的自动回复，同时保留 Chatwoot 的会话/分配/标签/报表/AI 建议等所有能力。

目标（Phase 1）：把现有 wecom-ai-service 作为「企业微信协议网关 + AI 后端」留在原位，给 Chatwoot 加一个一等公民的 Channel::Wecom，让 Chatwoot 的 agent UI 可以收发企业微信消息，而 AI 自动回复仍由 wecom-ai
触发（一旦 agent 介入则 handoff 停止 AI）。

v1 支持的消息类型：文本（必需）、图片、语音、文件/视频（可选但用户已选）。

AI 自动回复策略：保留 wecom-ai 的自动回复，通过 handoff 机制在 agent 介入时停止 AI。

Phase 2（暂缓）：把所有企业微信协议逻辑用纯 Ruby 重写到 Chatwoot，绕开 wecom-ai。

---
架构概览

┌────────────┐                  ┌─────────────────────┐                 ┌─────────────┐
│  企业微信    │  callback       │  wecom-ai-service   │                 │  Chatwoot   │
│  (微信用户)  │ ──────────────► │  (FastAPI)          │                 │  (Rails 7)  │
│            │  加密 XML +      │  ├─ AES 解密         │                 │             │
│            │  SHA1 签名       │  ├─ 拉取消息          │  POST           │             │
│            │                  │  ├─ 调 Coze/Dify     │ ─────────────►  │  Channel::   │
│            │ ◄──────────────  │  ├─ 发 AI 回复到 WeCom│   webhooks/    │  Wecom      │
│            │  AI 文本回复     │  └─ (新) 同步到       │   wecom/       │  Inbox      │
│            │                  │     Chatwoot          │   :open_kfid   │             │
└────────────┘                  │                     │                 └──────┬──────┘
                              │  POST /chatwoot/    │  handoff check   ▲      │
                              │  internal/...       │  (GET public)    │      │
                              │ ◄────────────────┐   │ ◄──────────┐   │      │
                              │  agent 在 Chatwoot│   │            │   │      │
                              │  composer 点发送  │   │            │   │      │
                              └─────────────────────┘                │      │
                                                                      │      │
                                              agent 登录 Chatwoot ◄────┘      │
                                              点 "发送" ──────────────────────┘

关键设计原则：
- 企业微信协议（加密、签名、媒体） → wecom-ai 负责（已实现、已测试）
- AI 自动回复 → wecom-ai 负责（已实现、已对接 Coze/Dify）
- Chatwoot 数据库（Contact、Conversation、Message） → Chatwoot 负责
- Agent UI、分配、标签、报表 → Chatwoot 负责
- Handoff 判定 → 从 Chatwoot 的 Conversation.status 派生（不存 wecom-ai 的 Redis）

---
关键 URL 设计（重要纠正）

┌─────────────────────┬───────────────────────────────────────────────────────────────────────┬─────────────────────────────┬──────────────────────────────────┐
│        方向         │                                  URL                                  │            鉴权             │               用途               │
├─────────────────────┼───────────────────────────────────────────────────────────────────────┼─────────────────────────────┼──────────────────────────────────┤
│ WeCom → Chatwoot    │ POST /webhooks/wecom/:open_kfid                                       │ HMAC (X-Chatwoot-Signature) │ wecom-ai 推送消息到 Chatwoot     │
├─────────────────────┼───────────────────────────────────────────────────────────────────────┼─────────────────────────────┼──────────────────────────────────┤
│ Chatwoot → wecom-ai │ POST /chatwoot/internal/send_message                                  │ HMAC (X-WecomAI-Signature)  │ agent 发消息时调用               │
├─────────────────────┼───────────────────────────────────────────────────────────────────────┼─────────────────────────────┼──────────────────────────────────┤
│ Chatwoot → wecom-ai │ POST /chatwoot/internal/upload_media                                  │ HMAC                        │ 上传 ActiveStorage 文件到 WeCom  │
├─────────────────────┼───────────────────────────────────────────────────────────────────────┼─────────────────────────────┼──────────────────────────────────┤
│ wecom-ai → Chatwoot │ GET /api/v1/public/wecom/handoff_status?external_userid=X&open_kfid=Y │ HMAC                        │ handoff 判定（每条新消息问一次） │
└─────────────────────┴───────────────────────────────────────────────────────────────────────┴─────────────────────────────┴──────────────────────────────────┘

Handoff 逻辑（最简）：
- wecom-ai 收到新消息 → 调 Chatwoot 的 /api/v1/public/wecom/handoff_status
- Chatwoot 查该 external_userid + open_kfid 对应的最近 conversation：
  - 找到 open 或 pending 状态的会话 → 返回 { handoff: true }（wecom-ai 跳过 AI 回复）
  - 只有 resolved 或无会话 → 返回 { handoff: false }（wecom-ai 走 AI 回复）
- 30 秒 Redis 缓存（wecom:handoff:<open_kfid>:<external_userid>），由 Conversation#status_changed 失效

---
实施步骤（5 个 Sprint）

Sprint 0 — 后端 model + DB

新建文件：
- db/migrate/<ts>_create_channel_wecom.rb
class CreateChannelWecom < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_wecom do |t|
      t.string  :corp_id, null: false
      t.string  :open_kfid, null: false
      t.string  :wecom_ai_service_url, null: false
      t.string  :wecom_ai_secret
      t.string  :bot_name
      t.integer :account_id, null: false
      t.timestamps
      t.index ['open_kfid'], name: 'idx_channel_wecom_on_open_kfid', unique: true
      t.index ['account_id'], name: 'idx_channel_wecom_on_account_id'
    end
  end
end
- app/models/channel/wecom.rb（参考 app/models/channel/telegram.rb）
  - include Channelable、include Reauthorizable
  - if Chatwoot.encryption_configured?; encrypts :wecom_ai_secret; end
  - self.table_name = 'channel_wecom'
  - EDITABLE_ATTRS = [:corp_id, :open_kfid, :wecom_ai_service_url, :wecom_ai_secret].freeze
  - 校验 corp_id / open_kfid / wecom_ai_service_url / wecom_ai_secret 必填；open_kfid 全局唯一
  - def name; 'Wecom'; end
  - def lock_to_single_conversation?; true; end（企业微信客服一个 customer 一个 session）

修改文件：
- app/models/account.rb — has_many :wecom_channels, dependent: :destroy_async, class_name: '::Channel::Wecom'
- app/models/inbox.rb — def wecom?; channel_type == 'Channel::Wecom'; end；callback_webhook_url case 加 when 'Channel::Wecom' then "#{ENV['FRONTEND_URL']}/webhooks/wecom/#{channel.open_kfid}"
- app/helpers/api/v1/inboxes_helper.rb — account_channels_method 加 'wecom' => Current.account.wecom_channels；inbox_name 加 wecom 分支
- app/controllers/api/v1/accounts/inboxes_controller.rb — allowed_channel_types 和 channel_type_from_params 加 'wecom' => Channel::Wecom

完成标志：rails db:migrate 通过，能 Account.first.wecom_channels.create!(...)。

Sprint 1 — 文本消息端到端

新建文件：
- app/controllers/webhooks/wecom_controller.rb（参考 app/controllers/webhooks/line_controller.rb）
class Webhooks::WecomController < ActionController::API
  def process_payload
    Webhooks::WecomEventsJob.perform_later(
      params: params.to_unsafe_hash,
      open_kfid: params[:open_kfid],
      post_body: request.raw_post,
      signature: request.headers['X-Chatwoot-Signature']
    )
    head :ok
  end
end
- app/jobs/webhooks/wecom_events_job.rb（参考 app/jobs/webhooks/line_events_job.rb）
  - queue_as :low，retry_on ActiveRecord::Deadlocked, wait: 3.seconds, attempts: 3
  - HMAC 校验（用 Channel::Wecom.find_by(open_kfid:) + channel.wecom_ai_secret）→ 调 Wecom::IncomingMessageService.new(inbox:).perform(params)
  - HMAC 失败 → channel.authorization_error!
- app/services/wecom/incoming_message_service.rb（参考 app/services/telegram/incoming_message_service.rb）
  - set_contact 用 ContactInboxWithContactBuilder.new(inbox, contact_attrs, source_id: external_userid).perform
  - set_conversation 用 ConversationBuilder（尊重 lock_to_single_conversation）
  - create_message：source_id = msgid（幂等键），message_type: :incoming, sender: @contact
  - 调 dispatch_create_events 触发正常事件链
- app/services/wecom/send_on_wecom_service.rb（参考 app/services/telegram/send_on_telegram_service.rb）
class Wecom::SendOnWecomService < Base::SendOnChannelService
  private
  def channel_class; Channel::Wecom; end
  def perform_reply
    result = Wecom::Outbound::SendTextService.new(message:).perform
    message.update!(source_id: result['msgid']) if result['msgid']
    Messages::StatusUpdateService.new(message, 'delivered').perform if result['errcode'].blank?
  rescue StandardError => e
    Messages::StatusUpdateService.new(message, 'failed', external_error: e.message).perform
  end
end
- app/services/wecom/outbound/{hmac_client,send_text_service}.rb — 共用 HMAC 客户端 + 文本发送 service

修改文件：
- app/jobs/send_reply_job.rb — CHANNEL_SERVICES 加 'Channel::Wecom' => ::Wecom::SendOnWecomService
- config/routes.rb — post 'webhooks/wecom/:open_kfid', to: 'webhooks/wecom#process_payload'
- app/views/api/v1/models/_inbox.json.jbuilder — if resource.wecom? 块（参考 line 117-118 admin-only 模式暴露 wecom_ai_secret）

wecom-ai 侧新增/修改：
- app/routes/chatwoot_internal.py（新文件）— POST /chatwoot/internal/send_message（接 {external_userid, open_kfid, msgtype:'text', text:{content}}，调现有 WeChatService.send_kf_message）
- app/services/chatwoot_sync_service.py（新文件）— HMAC 签名 + 调 Chatwoot /webhooks/wecom/:open_kfid、重试逻辑
- app/services/wechat.py（修改）— process_single_message 末尾调 ChatwootSyncService.notify_incoming(message_data)

完成标志：企业微信发文本 → wecom-ai → Chatwoot 看到会话，agent 手动回复 → wecom-ai 转发到 WeCom。

Sprint 2 — Handoff 机制

新建文件：
- app/controllers/api/v1/public/wecom/handoff_statuses_controller.rb
  - before_action :verify_hmac_signature
  - def show — 根据 external_userid + open_kfid 查最近 conversation 状态，返回 { handoff: bool, status: 'open'|'resolved' }
  - 30 秒 Redis 缓存（Rails.cache）
- app/services/wecom/handoff_query_service.rb
  - call(inbox, external_userid) 返回 OpenStruct.new(handoff:, status:)
  - 内部查 Conversation.where(contact_inbox.inbox_id: inbox.id, contact_inbox.source_id: external_userid).order(updated_at: :desc).first
  - handoff = conversation&.status.to_s.in?(%w[open pending])
- app/services/wecom/outbound/handoff_checker.rb（wecom-ai 侧）
  - 每次 AI 自动回复前调用
  - 调 Chatwoot /api/v1/public/wecom/handoff_status
  - 如果 handoff: true → 跳过 AI，直接 ACK WeCom

修改文件：
- config/routes.rb — namespace :public do; namespace :api do; namespace :v1 do; namespace :wecom do; resource :handoff_status, only: [:show]; end; end; end; end
- app/models/conversation.rb — 在 status_changed callback 失效缓存
- app/services/wechat.py（wecom-ai 侧）— process_single_message 之前先调 Wecom::HandoffChecker.check(...)

完成标志：会话 open → 用户发消息 → wecom-ai 跳过 AI；会话 resolved → 用户发消息 → wecom-ai 走 AI。

Sprint 3 — 多媒体（image / voice / file / video）

新建文件：
- app/services/wecom/send_attachments_service.rb（参考 app/services/telegram/send_attachments_service.rb）
  - 下载 ActiveStorage：attachment.file.blob.open { |f| ... }
  - 调 Wecom::Outbound::HmacClient.upload_media(file_bytes, mime, filename) 拿到 media_id
  - 调 Wecom::Outbound::SendMediaService.send_with_media_id(message, media_id, type)
- app/services/wecom/outbound/send_media_service.rb
- app/services/wecom/incoming_message_attachments_service.rb
  - wecom-ai 在调 Chatwoot webhook 时附带临时素材 URL
  - Chatwoot 用 Down.download(url) 流到 ActiveStorage
  - 按 msgtype 映射到 attachments[].file_type（image / audio / video / file）
- app/services/messages/markdown_renderers/wecom_renderer.rb（最简：转纯文本，因为企业微信客服只支持纯文本）

修改文件：
- app/services/wecom/incoming_message_service.rb — 增加 attachment 处理分支
- app/services/messages/markdown_renderer_service.rb — 加 'Channel::Wecom' => :render_wecom_plain

wecom-ai 侧：
- app/routes/chatwoot_internal.py 加 POST /chatwoot/internal/upload_media（接 multipart，存临时素材 bytes 走 /cgi-bin/media/upload，返回 media_id）

完成标志：用户发图片 → Chatwoot 看到；agent 发图片 → WeCom 用户收到。

Sprint 4 — 前端 UI

新建文件：
- app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Wecom.vue
  - 4 字段：corp_id、open_kfid、wecom_ai_service_url、wecom_ai_secret
  - 提交 dispatch inboxes/createChannel with { channel: { type: 'wecom', ... } }
  - 参考 app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Telegram.vue
- app/javascript/dashboard/api/channel/wecomChannel.js
- public/integrations/channels/badges/wecom.png（optional）

修改文件：
- app/javascript/dashboard/helper/inbox.js — INBOX_TYPES.WECOM = 'Channel::Wecom'；switch 里的图标/可读名
- app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue — 加 WeCom 卡片
- app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue — wecom: WeCom
- app/javascript/dashboard/components/widgets/ChannelItem.vue — whitelist 加 'wecom'
- app/javascript/dashboard/components-next/icon/provider.js — channelTypeIconMap 加 'Channel::Wecom': 'i-woot-wecom'
- app/javascript/dashboard/i18n/locale/en/inboxMgmt.json — INBOX_MGMT.ADD.WECOM_CHANNEL 块
- app/javascript/dashboard/i18n/locale/en/inbox.json — WECOM: "WeCom (企业微信)"
- app/javascript/dashboard/i18n/locale/zh_CN.json — 中文翻译

完成标志：管理员能在 UI 添加 WeCom 类型 inbox。

Sprint 5 — 生产加固（与 Sprint 4 并行）

新建文件：
- spec/factories/channel/channel_wecom.rb
- spec/models/channel/wecom_spec.rb
- spec/services/wecom/incoming_message_service_spec.rb
- spec/services/wecom/send_on_wecom_service_spec.rb
- spec/services/wecom/outbound/hmac_client_spec.rb
- spec/services/wecom/handoff_query_service_spec.rb
- spec/jobs/webhooks/wecom_events_job_spec.rb
- spec/controllers/webhooks/wecom_controller_spec.rb
- spec/controllers/api/v1/public/wecom/handoff_statuses_controller_spec.rb

加固项：
- 幂等性测试（重复 msgid 不创建重复 Message）
- 死信队列（wecom-ai 侧 wecom_outbox 表 + 定时重试）
- 健康检查：Chatwoot → wecom-ai /health 每 60s
- Reauthorizable 集成测试
- E2E：mock 完整链路

---
关键参考文件（实施时必读）

┌────────────────────────┬─────────────────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────┐
│          用途          │                                    文件                                     │                            原因                             │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Channel 模型模板       │ app/models/channel/telegram.rb                                              │ 含 Channelable + Reauthorizable + encrypts + EDITABLE_ATTRS │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Channelable concern    │ app/models/concerns/channelable.rb                                          │ 所有 channel 的基类                                         │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Reauthorizable concern │ app/models/concerns/reauthorizable.rb                                       │ HMAC 失败时自动重授权                                       │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Webhook 控制器模板     │ app/controllers/webhooks/line_controller.rb                                 │ 8 行 pattern                                                │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Webhook Job 模板       │ app/jobs/webhooks/line_events_job.rb                                        │ HMAC 校验 + channel 查找                                    │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 入站 service 模板      │ app/services/line/incoming_message_service.rb                               │ Event 数组 + lock_to_single_conversation                    │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 出站 service 模板      │ app/services/telegram/send_on_telegram_service.rb                           │ 继承 Base::SendOnChannelService                             │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 附件出站模板           │ app/services/telegram/send_attachments_service.rb                           │ 多类型分组 + 多部分上传                                     │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Contact 构建器         │ app/builders/contact_inbox_with_contact_builder.rb                          │ 幂等的 contact/contact_inbox                                │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 会话构建器             │ app/builders/conversation_builder.rb                                        │ lock_to_single_conversation                                 │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Inbox 模型             │ app/models/inbox.rb                                                         │ 多态 channel + callback_webhook_url                         │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Inbox 控制器           │ app/controllers/api/v1/accounts/inboxes_controller.rb                       │ 集中创建 channel                                            │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 公开端点 base          │ app/controllers/public_controller.rb                                        │ HMAC 验证                                                   │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ Jbuilder 模式          │ app/views/api/v1/models/_inbox.json.jbuilder                                │ 按 channel 类型条件块                                       │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 前端 channel 工厂      │ app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue │ 路由分发                                                    │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 前端 channel 选择      │ app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue    │ 卡片列表                                                    │
├────────────────────────┼─────────────────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤
│ 前端 INBOX_TYPES       │ app/javascript/dashboard/helper/inbox.js                                    │ channel 类型枚举                                            │
└────────────────────────┴─────────────────────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────┘

wecom-ai 侧参考：
- app/services/wechat.py — 现有 AES 解密、WeCom KF 收发消息、media 下载
- app/services/media.py — 临时素材下载 + pydub 转码
- app/services/multimodal.py — Coze/Dify 回复处理
- get_ai_service() 工厂（app/services/__init__.py）

---
复用的现有工具（不要新写）

┌────────────────────────────────┬────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────┐
│              工具              │                        位置                        │                           复用方式                           │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Base::SendOnChannelService     │ app/services/base/send_on_channel_service.rb       │ 直接继承                                                     │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ ContactInboxWithContactBuilder │ app/builders/contact_inbox_with_contact_builder.rb │ 直接调用                                                     │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ ConversationBuilder            │ app/builders/conversation_builder.rb               │ 直接调用                                                     │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Messages::MessageBuilder       │ app/builders/messages/message_builder.rb           │ 出站构造                                                     │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Messages::StatusUpdateService  │ app/services/messages/status_update_service.rb     │ 失败状态更新                                                 │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Redis::Alfred                  │ lib/redis/alfred.rb                                │ handoff 状态缓存                                             │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Reauthorizable concern         │ app/models/concerns/reauthorizable.rb              │ include                                                      │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Channelable concern            │ app/models/concerns/channelable.rb                 │ include                                                      │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ 加密：Rails 7 encrypts         │ Rails 内置                                         │ encrypts :wecom_ai_secret if Chatwoot.encryption_configured? │
├────────────────────────────────┼────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Pundit + InboxPolicy           │ app/policies/inbox_policy.rb                       │ 不需要新写 policy                                            │
└────────────────────────────────┴────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────┘

wecom-ai 侧复用：
- WeChatService 的 send_kf_message、download_media、decrypt_message_custom、verify_signature
- MediaService 的 pydub/ffmpeg 转码
- CozeService / DifyService 的 run_workflow
- get_ai_service() 工厂

---
风险与注意事项

1. 5 秒超时（最严重）：WeCom /wechat/kf/callback 要求 5 秒内回 success。wecom-ai 已用 BackgroundTasks 解耦；确保 wecom-ai 在 decrypt+parse 完成后立即 echo success，把 Chatwoot 推送放进同一个 BackgroundTasks
链（不能串行同步等）。
2. Handoff 必须从 Conversation.status 派生：不要在 wecom-ai 的 Redis 里存 flag。Chatwoot 端用 30s Redis 缓存 + Conversation 状态变更时失效。
3. wecom_ai_secret 必须加密：用 Rails 7 encrypts，和 Channel::Line.line_channel_secret 同样的模式。
4. open_kfid 全局唯一：用作 webhook URL 的路由 key，必须 unique index。
5. lock_to_single_conversation: true：企业微信客服一个 customer 一个 session 模式。在 Channel::Wecom#lock_to_single_conversation? 返回 true。
6. wecom-ai 侧多账户 / 多 KF account：每个 Channel::Wecom 对应一个 open_kfid。多 KF account 时建多个 Channel。
7. Media 上传的有效期：WeCom media_id 有效期 3 天，不要持久化到 Message model。每次发送都重新上传。
8. Idempotency：所有 Message 都用 source_id 存 wecom msgid，加 unique index (conversation_id, source_id)，写入前查重。
9. 企业微信客服消息频率限制：单客户 5 条/秒，单客服 30 条/秒。需要 Wecom::Outbound::RateLimiter（用 Redis 计数）。
10. Reauthorizable 必须配：如果 wecom-ai 的 secret 改了但 Chatwoot 没更新，HMAC 校验会失败。Reauthorizable 自动把这些错误计数到阈值后标 reauthorization_required?。

---
端到端验证步骤

# 1. 启动两个服务
cd /home/ranlei/wecom-ai-customer-service && ./deploy.sh   # wecom-ai
# Chatwoot 已在跑（http://localhost:3002）

# 2. 在 wecom-ai 的 .env 配 Chatwoot 对接
CHATWOOT_BASE_URL=http://<chatwoot-host>:3002
CHATWOOT_HMAC_SECRET=<any long random hex>

# 3. 在 Chatwoot UI 创建 Wecom inbox
# - 用 John (john@acme.inc / Password1!) 登录
# - Settings → Inboxes → Add Inbox → WeCom
# - 填 corp_id, open_kfid, wecom_ai_service_url, wecom_ai_secret

# 4. 在企业微信客服后台配回调
# - 回调 URL: http://<chatwoot-host>:3002/webhooks/wecom/<open_kfid>
# - Token: 同 wecom_ai_secret

# 5. 真实测试
# - 用微信扫企业微信客服的活码进入会话
# - 发文本 → 应在 Chatwoot 看到；几秒后 AI 自动回复
# - 切到 Chatwoot，agent 手动发一条 → 用户收到
# - 用户再发 → AI 不应再自动回复（handoff 生效）
# - 改状态到 resolved → 用户再发 → AI 又开始自动回复
# - 发图片 → 应该显示在 Chatwoot
# - agent 发图片 → 用户在 WeCom 收到

# 6. 验证 spec
cd /home/ranlei/chatwoot
bundle exec rspec spec/models/channel/wecom_spec.rb
bundle exec rspec spec/services/wecom/
bundle exec rspec spec/jobs/webhooks/wecom_events_job_spec.rb
bundle exec rspec spec/controllers/webhooks/wecom_controller_spec.rb
bundle exec rspec spec/controllers/api/v1/public/wecom/handoff_statuses_controller_spec.rb

---
实施顺序建议

按"先把端到端文本走通"原则：
1. 先做 Sprint 0 + Sprint 1（约 1-2 天）— 文本端到端跑通
2. 然后 Sprint 2（约 1 天）— handoff
3. 然后 Sprint 3（约 1-2 天）— 媒体
4. Sprint 4 + 5 并行（前端 + 测试）— 最后

每个 Sprint 完成后跑一次端到端测试。Sprint 1 完成时，文本消息应能在 Chatwoot 看到且能回复，标志 Phase 1 核心完成。