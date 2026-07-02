# frozen_string_literal: true

FactoryBot.define do
  factory :channel_wecom, class: 'Channel::Wecom' do
    corp_id { 'ww_test_corp_id' }
    sequence(:open_kfid) { |n| "wk_test_open_kfid_#{n}" }
    wecom_ai_service_url { 'http://172.20.0.1:1234' }
    sequence(:wecom_ai_secret) { |n| "spec_test_secret_#{n}" }
    bot_name { 'Wecom Test Bot' }
    account

    before(:create) do |channel, _evaluator|
      channel.define_singleton_method(:ensure_valid_credentials) { true }
    end

    after(:create) do |channel, _evaluator|
      # 手动建 inbox (避免 Inbox factory 嵌套 save! 抛错被吞)
      next if channel.reload.inbox.present?
      channel.create_inbox!(name: 'Wecom Test Inbox', account: channel.account)
    end
  end
end
