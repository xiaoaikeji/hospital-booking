<script setup>
import { computed, ref } from 'vue'
import { getAvailableSlots } from '@/mock/appointments.js'
import { getBookingSlots } from '@/mock/booking-schedule.js'
import { demoMode } from '@/store/session.js'
import { shiftLabels } from '../booking-calendar.js'

const props = defineProps({
  schedule: { type: Array, required: true },
  doctorId: { type: [Number, String], required: true },
  date: { type: String, required: true },
  selectedSlot: { type: String, default: '' },
  demo: Boolean,
})
const emit = defineEmits(['cancel', 'confirm'])
const selectedDate = ref(props.date)
const day = computed(() => props.schedule.find(item => item.date === selectedDate.value) || props.schedule[0])
const slots = computed(() => {
  if (!props.demo) return shiftLabels(day.value, props.doctorId).map(label => ({ label }))
  return demoMode ? getAvailableSlots(day.value, props.doctorId) : getBookingSlots(day.value, props.doctorId)
})
const choice = ref(props.selectedSlot)
const canPick = item => !props.demo || item.remaining > 0
const canConfirm = computed(() => day.value.date === selectedDate.value && slots.value.some(item => item.label === choice.value && canPick(item)))
const initialAnchor = 'day-' + day.value.date

function selectDay(item) {
  if (day.value.date === item.date) return
  selectedDate.value = item.date
  choice.value = ''
}

function confirm() {
  if (canConfirm.value) emit('confirm', { date: day.value.date, slot: choice.value })
}
</script>

<template>
  <view class="backdrop">
    <view class="dismiss-area" @tap="$emit('cancel')" @touchmove.stop.prevent />
    <view class="slot-sheet" aria-role="dialog" aria-label="选择预约时段">
      <view class="sheet-title">预约</view>
      <view v-if="demo" class="sheet-note">为了更好的服务，请提前一天预约</view>
      <scroll-view scroll-x class="day-strip" :scroll-into-view="initialAnchor" :show-scrollbar="false">
        <view class="days">
          <view v-for="item in schedule" :id="'day-' + item.date" :key="item.date" class="day"
            :class="{ active: item.date === day.date }" @tap="selectDay(item)">
            <text>{{ item.weekday }}</text><text class="day-date">{{ item.label }}</text>
          </view>
        </view>
      </scroll-view>
      <scroll-view scroll-y class="slots-scroll">
        <view class="slots">
          <button v-for="item in slots" :key="item.label" class="slot" :class="{ chosen: canConfirm && item.label === choice, full: !canPick(item) }"
            :disabled="!canPick(item)" @tap="choice = item.label">
            <text>{{ item.label }}</text><text v-if="demo" class="remaining">余号：{{ item.remaining }}</text>
          </button>
        </view>
        <view v-if="!demo && !slots.length" class="sheet-note" role="status">当日暂无排班</view>
      </scroll-view>
      <view class="sheet-actions">
        <button class="cancel" @tap="$emit('cancel')">取消</button>
        <button class="confirm" :class="{ disabled: !canConfirm }" :disabled="!canConfirm" @tap="confirm">确定<text v-if="canConfirm"> ({{ day.label }} {{ choice }})</text></button>
      </view>
    </view>
  </view>
</template>

<style scoped>
.backdrop { position: fixed; inset: 0; z-index: 3; display: flex; align-items: flex-end; background: rgba(0,0,0,.40); }
.dismiss-area { position: absolute; inset: 0; }
.slot-sheet { position: relative; display: flex; flex-direction: column; box-sizing: border-box; width: 100%; height: min(1184rpx, 82vh); padding-bottom: env(safe-area-inset-bottom); background: #fff; animation: sheet-in .22s ease-out; }
.sheet-title { margin: 30rpx 30rpx 0; font-size: 28rpx; line-height: 42rpx; }
.sheet-note { margin: 0 30rpx; font-size: 24rpx; line-height: 36rpx; }
.day-strip { flex: none; margin-top: 18rpx; white-space: nowrap; }
.days { display: inline-flex; vertical-align: top; }
.day { box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; width: 112rpx; height: 120rpx; border-bottom: 5rpx solid transparent; font-size: 26rpx; line-height: 38rpx; }
.day.active { border-color: #5fa8e3; }
.day-date { font-size: 22rpx; line-height: 32rpx; }
.slots-scroll { flex: 1; height: 0; min-height: 0; }
.slots { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 18rpx; padding: 40rpx 30rpx; }
.slot { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6rpx; box-sizing: border-box; width: 100%; height: 112rpx; padding: 0; border: 1rpx solid #dedfeb; border-radius: 8rpx; background: #f2f2fc; color: #111; font-size: 25rpx; line-height: 32rpx; }
.slot.full { background: #f8f8f8; color: #ccc; }
.slot.chosen { background: #5ba6e5; color: #fff; }
.remaining { font-size: 22rpx; }
.sheet-actions { display: flex; }
.sheet-actions .cancel, .sheet-actions .confirm { margin: 0; border-radius: 0; font-size: 28rpx; line-height: 76rpx; }
.cancel { width: 158rpx; background: #fff; color: #111; }
.confirm { flex: 1; padding: 0; background: #5ba6e5; color: #fff; }
.confirm.disabled { background: #d5d5d5; color: #fff; }
.slot::after, .confirm::after, .cancel::after { border: 0; }
@keyframes sheet-in { from { transform: translateY(100%); } to { transform: translateY(0); } }
</style>
