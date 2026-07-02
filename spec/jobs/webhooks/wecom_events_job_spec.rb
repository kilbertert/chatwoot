# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WecomEventsJob do
  let(:account) { create(:account) }
  let!(:wecom_channel) { create(:channel_wecom, account: account, wecom_ai_secret: 'spec_test_secret') }
  let(:inbox) { wecom_channel.inbox }
  let(:open_kfid) { wecom_channel.open_kfid }
  let(:post_body) { '{"open_kfid":"wk_test","external_userid":"wm_test","contact":{"name":"Test"},"message":{"msgid":"spec_001","msgtype":"text","text":{"content":"hi"}}}' }
  let(:signature) { OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), wecom_channel.wecom_ai_secret, post_body) }
  let(:params) { JSON.parse(post_body) }

  def perform_job(overrides = {})
    args = {
      params: params,
      open_kfid: open_kfid,
      post_body: post_body,
      signature: signature,
      trigger_bot_handoff: false
    }.merge(overrides)

    described_class.perform_now(**args)
  end

  context 'when trigger_bot_handoff=true' do
    it 'triggers Conversation#bot_handoff! instead of message processing' do
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account), source_id: 'wm_test')
      conv = create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox, status: :pending)

      expect(Wecom::IncomingMessageService).not_to receive(:new)

      perform_job(trigger_bot_handoff: true)
      expect(conv.reload.status).to eq('open')
    end
  end

  context 'when HMAC signature invalid' do
    it 'returns nil and does not process' do
      expect(Wecom::IncomingMessageService).not_to receive(:new)
      result = perform_job(signature: 'invalid_signature')
      expect(result).to be_nil
    end
  end

  context 'when channel not found' do
    it 'returns nil' do
      result = perform_job(open_kfid: 'non_existent')
      expect(result).to be_nil
    end
  end

  context 'when account is suspended' do
    it 'returns nil and does not process' do
      wecom_channel.account.update!(status: :suspended)
      expect(Wecom::IncomingMessageService).not_to receive(:new)
      result = perform_job
      expect(result).to be_nil
    end
  end

  context 'when trigger_bot_handoff=false (normal message)' do
    it 'delegates to Wecom::IncomingMessageService' do
      service = double('Wecom::IncomingMessageService')
      allow(Wecom::IncomingMessageService).to receive(:new).with(inbox: inbox, params: kind_of(Hash)).and_return(service)
      expect(service).to receive(:perform)
      perform_job
    end
  end
end
