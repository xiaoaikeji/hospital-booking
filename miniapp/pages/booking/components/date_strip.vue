<script setup>
defineProps({
  schedule: { type: Array, required: true },
  selected: { type: String, default: '' },
  compact: Boolean,
})
defineEmits(['select'])
</script>

<template>
  <scroll-view scroll-x class="date-strip" :show-scrollbar="false">
    <view class="date-options" :class="{ compact }">
      <view v-for="item in schedule" :key="item.date" class="date-option"
        :class="{ 'date-selected': item.date === selected }" role="button" @tap="$emit('select', item)">
        <text>{{ item.weekday }}</text><text class="calendar-date">{{ item.label }}</text>
      </view>
    </view>
  </scroll-view>
</template>

<style scoped>
.date-strip { width: 100%; white-space: nowrap; }
.date-options { display: inline-flex; width: max-content; gap: 20rpx; padding: 22rpx 20rpx 25rpx; vertical-align: top; }
.date-option { flex: none; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4rpx; width: 98rpx; height: 100rpx; border-radius: 8rpx; background: #f5f4fa; font-size: 26rpx; line-height: 36rpx; }
.date-selected { background: #5da8e4; color: #fff; }
.calendar-date { font-size: 22rpx; font-weight: 300; line-height: 30rpx; }
.date-options.compact { padding-top: 10rpx; padding-bottom: 15rpx; }
</style>
