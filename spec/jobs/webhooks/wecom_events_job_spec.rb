# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WecomEventsJob do
  let(:account) { create(:account) }
  let!(:wecom_channel) { create(:channel_wecom, account: account, wecom_ai_secret: 'spec_test_secret') }
  let(:inbox) { wecom_channel.inbox }
  let(:open_kfid) { wecom_channel.open_kfid }
  let(:post_body) do
    {
      open_kfid: 'wk_test',
      external_userid: 'wm_test',
      contact: { name: 'Test' },
      message: { msgid: 'spec_001', msgtype: 'text', text: { content: 'hi' } }
    }.to_json
  end
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

    it 'does not trigger handoff for resolved conversations' do
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account), source_id: 'wm_test')
      conv = create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox, status: :resolved)

      expect(Wecom::IncomingMessageService).not_to receive(:new)

      perform_job(trigger_bot_handoff: true)
      expect(conv.reload.status).to eq('resolved')
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
    let(:service) { instance_double(Wecom::IncomingMessageService) }
    let(:lock_manager) { instance_double(Redis::LockManager) }
    let(:lock_key) { format(Redis::Alfred::WECOM_MESSAGE_MUTEX, inbox_id: inbox.id, external_userid: 'wm_test') }

    before do
      allow(Wecom::IncomingMessageService).to receive(:new).with(inbox: inbox, params: kind_of(Hash)).and_return(service)
      allow(service).to receive(:perform)
      allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
      allow(lock_manager).to receive(:lock).and_return(true)
      allow(lock_manager).to receive(:unlock).and_return(true)
    end

    it 'delegates to Wecom::IncomingMessageService inside the WeCom mutex' do
      expect(lock_manager).to receive(:lock).with(lock_key, 5.seconds).and_return(true)
      expect(lock_manager).to receive(:unlock).with(lock_key).and_return(true)
      expect(service).to receive(:perform)

      perform_job
    end

    it 'accepts positional job arguments when processing without the lock' do
      expect(Rails.logger).to receive(:warn).with('[Webhooks::WecomEventsJob] Processing without lock after lock retry exhaustion')
      expect(service).to receive(:perform)

      described_class.new.process_without_lock(
        {
          'params' => params,
          'open_kfid' => open_kfid,
          'post_body' => post_body,
          'signature' => signature,
          'trigger_bot_handoff' => false
        }
      )
    end

    it 'survives a non-LockAcquisitionError raised inside the lock block' do
      # Errors other than LockAcquisitionError are re-raised by MutexApplicationJob
      # and must not silently fall through to process_without_lock.
      allow(lock_manager).to receive(:lock).and_return(true)
      allow(lock_manager).to receive(:unlock).and_return(true)
      allow(service).to receive(:perform).and_raise(StandardError, 'boom')

      expect { perform_job }.to raise_error(StandardError, 'boom')
    end
  end

  describe 'process_without_lock argument unwrap' do
    let(:service) { instance_double(Wecom::IncomingMessageService) }
    let(:job_args_hash) do
      {
        'params' => params,
        'open_kfid' => open_kfid,
        'post_body' => post_body,
        'signature' => signature,
        'trigger_bot_handoff' => false
      }
    end

    before do
      allow(Wecom::IncomingMessageService).to receive(:new).with(inbox: inbox, params: kind_of(Hash)).and_return(service)
      allow(service).to receive(:perform)
    end

    it 'matches the ActiveJob retry_on argument shape (splat of single hash)' do
      # `MutexApplicationJob#retry_on_lock_conflict` invokes on exhaustion:
      #   job.public_send(on_exhaustion, *job.arguments)
      # For a job enqueued via `perform_later(**kwargs)`, `job.arguments` is a
      # 1-element array whose only element is the kwargs hash. Splatting that
      # gives a single positional hash — exactly the shape that must reach
      # process_without_lock's `args.first` branch.
      job = described_class.new
      expect(service).to receive(:perform)
      expect(Rails.logger).to receive(:warn).with(/Processing without lock after lock retry exhaustion/)

      job.process_without_lock(job_args_hash)
    end

    it 'survives a fully empty argument set without raising' do
      job = described_class.new

      expect { job.process_without_lock({}) }.not_to raise_error
    end
  end
end
