# == Schema Information
#
# Table name: channel_wecom
#
#  id                   :bigint           not null, primary key
#  bot_name             :string
#  open_kfid            :string           not null
#  wecom_ai_secret      :string
#  wecom_ai_service_url :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :integer          not null
#  corp_id              :string           not null
#
# Indexes
#
#  idx_channel_wecom_on_account_id  (account_id)
#  idx_channel_wecom_on_open_kfid   (open_kfid) UNIQUE
#

class Channel::Wecom < ApplicationRecord
  include Channelable
  include Reauthorizable

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  if Chatwoot.encryption_configured?
    encrypts :wecom_ai_secret
  end

  self.table_name = 'channel_wecom'
  EDITABLE_ATTRS = [:corp_id, :open_kfid, :wecom_ai_service_url, :wecom_ai_secret].freeze

  validates :corp_id, presence: true
  validates :open_kfid, presence: true, uniqueness: true
  validates :wecom_ai_service_url, presence: true
  validates :wecom_ai_secret, presence: true

  def name
    'Wecom'
  end

  # 企业微信客服是 "一个 customer 一个 session" 模式,
  # 强制 lock_to_single_conversation 避免在 Chatwoot 端产生多个并行会话
  def lock_to_single_conversation?
    true
  end
end
