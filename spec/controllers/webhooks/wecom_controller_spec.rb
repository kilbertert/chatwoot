# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WecomController, type: :request do
  let(:account) { create(:account) }
  let!(:wecom_channel) { create(:channel_wecom, account: account, wecom_ai_secret: 'spec_test_secret') }
  let(:open_kfid) { wecom_channel.open_kfid }
  let(:body_params) do
    {
      'open_kfid' => open_kfid,
      'external_userid' => 'wm_test',
      'contact' => { 'name' => 'T' },
      'message' => {
        'msgid' => 'ctrl_001',
        'msgtype' => 'text',
        'text' => { 'content' => 'hi' }
      }
    }
  end
  let(:post_body) { JSON.generate(body_params) }
  let(:signature) { signature_for(post_body) }

  def signature_for(body, secret = wecom_channel.wecom_ai_secret)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), secret, body)
  end

  def post_wecom_webhook(open_kfid, body, signature_header = signature)
    headers = { 'Content-Type' => 'application/json' }
    headers['X-WecomAI-Signature'] = signature_header unless signature_header.nil?

    post "/webhooks/wecom/#{open_kfid}", params: body, headers: headers
  end

  describe 'POST /webhooks/wecom/:open_kfid' do
    context 'with valid HMAC signature' do
      it 'enqueues Webhooks::WecomEventsJob' do
        expect {
          post_wecom_webhook(open_kfid, post_body)
        }.to have_enqueued_job(Webhooks::WecomEventsJob).with(
          params: body_params,
          open_kfid: open_kfid,
          post_body: post_body,
          signature: signature,
          trigger_bot_handoff: false
        )
        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the payload requests bot handoff' do
      let(:body_params) { super().merge('reason' => 'ai_handoff') }

      it 'enqueues the job with trigger_bot_handoff enabled' do
        expect {
          post_wecom_webhook(open_kfid, post_body)
        }.to have_enqueued_job(Webhooks::WecomEventsJob).with(
          params: body_params,
          open_kfid: open_kfid,
          post_body: post_body,
          signature: signature,
          trigger_bot_handoff: true
        )
        expect(response).to have_http_status(:ok)
      end
    end

    context 'with missing HMAC signature' do
      it 'does not enqueue the job' do
        expect {
          post_wecom_webhook(open_kfid, post_body, nil)
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with invalid HMAC signature' do
      it 'does not enqueue the job' do
        expect {
          post_wecom_webhook(open_kfid, post_body, 'invalid')
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with a signature for a different body' do
      it 'does not enqueue the job' do
        tampered_body = JSON.generate(body_params.merge('external_userid' => 'wm_tampered'))

        expect {
          post_wecom_webhook(open_kfid, tampered_body, signature)
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with non-existent channel' do
      it 'does not enqueue the job' do
        expect {
          post_wecom_webhook('non_existent_kfid', post_body)
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with empty body' do
      it 'does not enqueue the job' do
        expect {
          post_wecom_webhook(open_kfid, '')
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with malformed JSON body' do
      it 'does not enqueue the job' do
        expect {
          post_wecom_webhook(open_kfid, '{')
        }.not_to have_enqueued_job(Webhooks::WecomEventsJob)
        expect(response).to have_http_status(:bad_request)
      end
    end
  end
end
