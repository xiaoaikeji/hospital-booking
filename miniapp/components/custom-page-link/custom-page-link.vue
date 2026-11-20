<script setup>
import { openPageLink } from '@/utils/page-link.js'

defineOptions({ options: { virtualHost: true } })
const props = defineProps({ link: { type: Object, required: true } })
</script>

<template>
  <button v-if="link.link_type === 'contact'" class="page-link contact-link" open-type="contact" hover-class="none" :aria-label="link.name">
    <slot />
  </button>
  <view v-else class="page-link" :aria-role="link.link_type === 'none' ? undefined : 'link'" @tap="openPageLink(props.link)">
    <slot />
  </view>
</template>

<style scoped>
.page-link { display: block; width: 100%; height: 100%; }
.contact-link { margin: 0; padding: 0; border: 0; border-radius: 0; color: inherit; background: transparent; line-height: inherit; text-align: inherit; }
.contact-link::after { border: 0; }
</style>
