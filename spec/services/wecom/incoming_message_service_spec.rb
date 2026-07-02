# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wecom::IncomingMessageService do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_wecom, account: account) }
  let(:inbox) { channel.inbox.reload }
  let(:external_userid) { 'wm_test_external_001' }
  let(:msg_id) { 'wecom_test_msg_001' }

  def build_params(origin: 1, msgtype: 'text', content: '客户发的消息')
    {
      'open_kfid' => channel.open_kfid,
      'external_userid' => external_userid,
      'contact' => { 'name' => 'Test Contact', 'avatar' => '' },
      'message' => {
        'msgid' => msg_id,
        'msgtype' => msgtype,
        'text' => { 'content' => content },
        'origin' => origin
      }
    }
  end

  describe '#perform with origin=1 (customer message)' do
    it 'creates an incoming message with sender=Contact' do
      service = described_class.new(inbox: inbox, params: build_params(origin: 1).with_indifferent_access)
      service.perform

      m = Message.find_by(source_id: msg_id)
      expect(m).not_to be_nil
      expect(m.message_type).to eq('incoming')
      expect(m.sender_type).to eq('Contact')
      expect(m.content).to eq('客户发的消息')
    end
  end

  describe '#perform with origin=2 (AI reply)' do
    before do
      create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: account))
      contact = create(:contact, account: account)
      ci = create(:contact_inbox, inbox: inbox, contact: contact, source_id: external_userid)
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: ci)
    end

    it 'creates an outgoing message with sender=AgentBot' do
      ai_msg_id = 'wecom_ai_msg_001'
      params = build_params(origin: 2, msgtype: 'text', content: 'AI 自动回复')
      params['message']['msgid'] = ai_msg_id

      service = described_class.new(inbox: inbox, params: params.with_indifferent_access)
      service.perform

      m = Message.find_by(source_id: ai_msg_id)
      expect(m).not_to be_nil
      expect(m.message_type).to eq('outgoing')
      expect(m.sender_type).to eq('AgentBot')
    end
  end

  describe '#perform with image attachment (Sprint 3)' do
    before do
      contact = create(:contact, account: account)
      ci = create(:contact_inbox, inbox: inbox, contact: contact, source_id: external_userid)
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: ci)
    end

    it 'creates attachment from base64 chatwoot_attachment' do
      image_msg_id = 'wecom_img_001'
      png_b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+P+/HgAFhAJ/wlseKgAAAABJRU5ErkJggg=='
      params = build_params(origin: 1, msgtype: 'image', content: '')
      params['message']['msgid'] = image_msg_id
      params['message']['chatwoot_attachment'] = {
        'base64' => png_b64,
        'content_type' => 'image/png',
        'filename' => 'test.png',
        'size' => 70
      }

      service = described_class.new(inbox: inbox, params: params.with_indifferent_access)
      service.perform

      m = Message.find_by(source_id: image_msg_id)
      expect(m).not_to be_nil
      expect(m.attachments.count).to eq(1)
      att = m.attachments.first
      expect(att.file_type).to eq('image')
      expect(att.file.byte_size).to eq(70)
    end
  end

  describe '#perform is idempotent (already_processed check)' do
    it 'does not create duplicate messages' do
      service = described_class.new(inbox: inbox, params: build_params(origin: 1).with_indifferent_access)
      service.perform
      expect { service.perform }.not_to change { Message.count }
    end
  end

  describe '#perform skips resolved conversation (E5)' do
    before do
      contact = create(:contact, account: account)
      ci = create(:contact_inbox, inbox: inbox, contact: contact, source_id: external_userid)
      @resolved_conv = create(:conversation, account: account, inbox: inbox,
                              contact: contact, contact_inbox: ci, status: :resolved)
    end

    it 'opens a NEW conversation instead of appending to the resolved one' do
      service = described_class.new(inbox: inbox, params: build_params(origin: 1).with_indifferent_access)
      service.perform

      m = Message.find_by(source_id: msg_id)
      expect(m).not_to be_nil
      expect(m.conversation_id).not_to eq(@resolved_conv.id)
      expect(m.conversation.status).to eq('open')
      expect(@resolved_conv.reload.status).to eq('resolved') # 旧会话保持 resolved, 未被 reopen
    end
  end
end
