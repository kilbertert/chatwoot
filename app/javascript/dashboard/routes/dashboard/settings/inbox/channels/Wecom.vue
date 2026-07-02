<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      corpId: '',
      openKfid: '',
      wecomAiServiceUrl: '',
      wecomAiSecret: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    corpId: { required },
    openKfid: { required },
    wecomAiServiceUrl: { required },
    wecomAiSecret: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const wecomChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'wecom',
              corp_id: this.corpId?.trim(),
              open_kfid: this.openKfid?.trim(),
              wecom_ai_service_url: this.wecomAiServiceUrl?.trim(),
              wecom_ai_secret: this.wecomAiSecret?.trim(),
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: wecomChannel.id,
          },
        });
      } catch (error) {
        useAlert(
          error.message ||
            this.$t('INBOX_MGMT.ADD.WECOM_CHANNEL.API.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0 mb-4">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.PLACEHOLDER')"
            @blur="v$.channelName.$touch"
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0 mb-4">
        <label :class="{ error: v$.corpId.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.LABEL') }}
          <input
            v-model="corpId"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.PLACEHOLDER')"
            @blur="v$.corpId.$touch"
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0 mb-4">
        <label :class="{ error: v$.openKfid.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.LABEL') }}
          <input
            v-model="openKfid"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.PLACEHOLDER')"
            @blur="v$.openKfid.$touch"
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0 mb-4">
        <label :class="{ error: v$.wecomAiServiceUrl.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SERVICE_URL.LABEL') }}
          <input
            v-model="wecomAiServiceUrl"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SERVICE_URL.PLACEHOLDER')"
            @blur="v$.wecomAiServiceUrl.$touch"
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SERVICE_URL.SUBTITLE') }}
        </p>
      </div>

      <div class="flex-shrink-0 flex-grow-0 mb-4">
        <label :class="{ error: v$.wecomAiSecret.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SECRET.LABEL') }}
          <input
            v-model="wecomAiSecret"
            type="password"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SECRET.PLACEHOLDER')"
            @blur="v$.wecomAiSecret.$touch"
          />
        </label>
        <p class="help-text">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.AI_SECRET.SUBTITLE') }}
        </p>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
