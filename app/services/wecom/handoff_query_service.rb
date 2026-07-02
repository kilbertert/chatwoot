# frozen_string_literal: true

# Sprint 2: 查 handoff 状态
# 8501 wecom-ai 在调 Dify 前调本 service, 决定走 AI 路径还是转人工
#
# 规则 (用户确认):
#   1. Conversation.assignee_id 必须有值 (有 agent 接手)
#   2. 该 agent 必须 online (OnlineStatusTracker Redis presence)
#   两个条件同时满足才 handoff: true
class Wecom::HandoffQueryService
  pattr_initialize [:open_kfid!, :external_userid!]

  def perform
    channel = Channel::Wecom.find_by(open_kfid: open_kfid)
    return { handoff: false, reason: 'channel_not_found' } if channel.nil?

    inbox = channel.inbox
    return { handoff: false, reason: 'inbox_not_found' } if inbox.nil?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: external_userid)
    return { handoff: false, reason: 'no_conversation' } if contact_inbox.nil?

    # E5: 跳过 resolved 会话 —— 已解决这轮不再查 handoff (返回 no_conversation
    # 让 wecom-ai 走 AI; 客户再来时 incoming 会开新会话)。
    conversation = contact_inbox.conversations.where.not(status: :resolved).last
    return { handoff: false, reason: 'no_conversation' } if conversation.nil?
    return { handoff: false, reason: 'unassigned' } if conversation.assignee_id.blank?

    assignee = conversation.assignee
    # E6 防御: assignee_id 存在但 User 被硬删时 assignee 为 nil (belongs_to 默认不报错),
    # 旧版直接 assignee.id 会 NoMethodError → 公开端点 500。nil 时当 unassigned。
    return { handoff: false, reason: 'unassigned' } if assignee.nil?
    # OnlineStatusTracker 返回 String 数组, assignee.id 是 Integer, 要 map(&:to_i) 后再 include?
    is_online = OnlineStatusTracker.get_available_user_ids(inbox.account_id).map(&:to_i).include?(assignee.id)

    {
      handoff: is_online,
      reason: is_online ? 'agent_online' : 'agent_offline',
      assignee_id: assignee.id,
      assignee_name: assignee.name,
      conversation_id: conversation.id,
      is_online: is_online
    }
  end
end
