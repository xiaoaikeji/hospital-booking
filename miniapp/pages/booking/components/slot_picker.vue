<script setup>
import { computed, ref, watch } from 'vue'
import { getAvailableSlots } from '@/mock/appointments.js'
import { getBookingSlots } from '@/mock/booking-schedule.js'
import { bookingNow } from '@/store/app-configuration.js'
import { demoMode } from '@/store/session.js'
import { bookingShifts, bookingSlotKey, bookingSlots, shiftBookable, shiftClosed, shiftSlots } from '../booking-calendar.js'

const props = defineProps({
  schedule: { type: Array, required: true },
  doctorId: { type: [Number, String], required: true },
  date: { type: String, required: true },
  selectedSlot: { type: Object, default: null },
  now: { type: Number, required: true },
  demo: Boolean,
})
const emit = defineEmits(['cancel', 'confirm'])
const onlyBookable = ref(false)
const selectedDate = ref(props.date)
const visibleDays = computed(() => onlyBookable.value
  ? props.schedule.filter(day => slotsForDay(day).some(item => shiftBookable(item, props.now)))
  : props.schedule)
const day = computed(() => visibleDays.value.find(item => item.date === selectedDate.value) || visibleDays.value[0])
const sections = computed(() => {
  const shifts = props.demo ? [] : bookingShifts(day.value, props.doctorId)
  if (shifts.some(shift => shift.slots)) {
    return shifts.map(shift => ({ key: shift.time_slot, title: shiftHeading(shift), slots: shiftSlots(shift) }))
  }
  const options = slotsForDay(day.value)
  return options.length ? [{ key: 'day', slots: options }] : []
})
const slots = computed(() => sections.value.flatMap(section => section.slots))
const choice = ref(props.selectedSlot ? bookingSlotKey(props.selectedSlot) : '')
const chosenSlot = computed(() => slots.value.find(item => bookingSlotKey(item) === choice.value))
const canConfirmAt = now => day.value?.date === selectedDate.value && !!chosenSlot.value && shiftBookable(chosenSlot.value, now)
const canConfirm = computed(() => canConfirmAt(props.now))
const scrollAnchor = ref(day.value ? 'day-' + day.value.date : '')

watch([day, canConfirm], ([activeDay, bookable]) => {
  if (!bookable) choice.value = ''
  const activeDate = activeDay?.date || ''
  if (selectedDate.value !== activeDate) {
    selectedDate.value = activeDate
    scrollAnchor.value = activeDate ? 'day-' + activeDate : ''
  }
})

function slotsForDay(day) {
  if (!day) return []
  if (!props.demo) return bookingSlots(day, props.doctorId)
  return demoMode ? getAvailableSlots(day, props.doctorId) : getBookingSlots(day, props.doctorId)
}

function selectDay(item) {
  if (day.value?.date === item.date) return
  selectedDate.value = item.date
  choice.value = ''
}

function selectSlot(item) {
  if (shiftBookable(item, bookingNow())) choice.value = bookingSlotKey(item)
}

function shiftHeading(shift) {
  const next = shift.slots.find(slot => !shiftClosed(slot, props.now))
  const status = next ? `当前可约 ${next.shift_available} 号` : '已截止'
  return `${shift.label} · 共 ${shift.total} 号 · ${status}`
}

function shiftText(item) {
  const parts = [item.label]
  if (item.total != null) parts.push(`共 ${item.total} 号`)
  const status = slotStatus(item)
  if (status) parts.push(status)
  return parts.join(' · ')
}

function slotStatus(item) {
  if (shiftClosed(item, props.now)) return '已截止'
  if (item.remaining === 0) return '已满'
  if (item.remaining != null) return `${item.timed ? '余' : '剩'} ${item.remaining} 号`
  return ''
}

function confirm() {
  if (canConfirmAt(bookingNow())) emit('confirm', { doctorId: props.doctorId, date: day.value.date, slot: chosenSlot.value })
}
</script>

<template>
  <view class="backdrop">
    <view class="dismiss-area" @tap="$emit('cancel')" @touchmove.stop.prevent />
    <view class="slot-sheet" aria-role="dialog" aria-label="选择预约时段">
      <view class="sheet-heading">
        <view class="sheet-title">预约</view>
        <checkbox-group @change="onlyBookable = !!$event.detail.value.length">
          <label class="only-bookable"><checkbox value="bookable" :checked="onlyBookable" color="#5ba6e5" />只看有号</label>
        </checkbox-group>
      </view>
      <view v-if="demo" class="sheet-note">为了更好的服务，请提前一天预约</view>
      <scroll-view v-if="visibleDays.length" scroll-x class="day-strip" :scroll-into-view="scrollAnchor" :show-scrollbar="false">
        <view class="days">
          <view v-for="item in visibleDays" :id="'day-' + item.date" :key="item.date" class="day"
            :class="{ active: item.date === day.date }" @tap="selectDay(item)">
            <text>{{ item.weekday }}</text><text class="day-date">{{ item.label }}</text>
          </view>
        </view>
      </scroll-view>
      <scroll-view scroll-y class="slots-scroll">
        <view v-for="section in sections" :key="section.key" class="slot-section">
          <view v-if="section.title" class="shift-heading">{{ section.title }}</view>
          <view v-if="section.slots.length" class="slots">
            <button v-for="item in section.slots" :key="bookingSlotKey(item)" class="slot"
              :class="{ 'shift-slot': !demo && !item.timed, chosen: canConfirm && bookingSlotKey(item) === choice, full: !shiftBookable(item, now) }"
              :disabled="!shiftBookable(item, now)" @tap="selectSlot(item)">
              <template v-if="demo || item.timed">
                <text>{{ item.label }}</text><text class="remaining">{{ demo ? `余号：${item.remaining}` : slotStatus(item) }}</text>
              </template>
              <text v-else>{{ shiftText(item) }}</text>
            </button>
          </view>
        </view>
        <view v-if="onlyBookable && !visibleDays.length" class="sheet-note" role="status">暂无可约日期</view>
        <view v-else-if="!demo && !slots.length" class="sheet-note" role="status">当日暂无排班</view>
      </scroll-view>
      <view class="sheet-actions">
        <button class="cancel" @tap="$emit('cancel')">取消</button>
        <button class="confirm" :class="{ disabled: !canConfirm }" :disabled="!canConfirm" @tap="confirm">确定<text v-if="canConfirm"> ({{ day.label }} {{ chosenSlot.label }})</text></button>
      </view>
    </view>
  </view>
</template>

<style scoped>
.backdrop { position: fixed; inset: 0; z-index: 3; display: flex; align-items: flex-end; background: rgba(0,0,0,.40); }
.dismiss-area { position: absolute; inset: 0; }
.slot-sheet { position: relative; display: flex; flex-direction: column; box-sizing: border-box; width: 100%; height: min(1184rpx, 82vh); padding-bottom: env(safe-area-inset-bottom); background: #fff; animation: sheet-in .22s ease-out; }
.sheet-heading { display: flex; align-items: center; justify-content: space-between; margin: 30rpx 30rpx 0; }
.sheet-title { font-size: 28rpx; line-height: 42rpx; }
.only-bookable { display: flex; align-items: center; color: #555; font-size: 24rpx; line-height: 42rpx; }
.only-bookable checkbox { transform: scale(.75); }
.sheet-note { margin: 0 30rpx; font-size: 24rpx; line-height: 36rpx; }
.day-strip { flex: none; margin-top: 18rpx; white-space: nowrap; }
.days { display: inline-flex; vertical-align: top; }
.day { box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; width: 112rpx; height: 120rpx; border-bottom: 5rpx solid transparent; font-size: 26rpx; line-height: 38rpx; }
.day.active { border-color: #5fa8e3; }
.day-date { font-size: 22rpx; line-height: 32rpx; }
.slots-scroll { flex: 1; height: 0; min-height: 0; }
.slot-section { padding: 26rpx 30rpx 14rpx; }
.shift-heading { margin-bottom: 18rpx; font-size: 26rpx; line-height: 38rpx; }
.slots { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 18rpx; }
.slot { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6rpx; box-sizing: border-box; width: 100%; height: 112rpx; padding: 0; border: 1rpx solid #dedfeb; border-radius: 8rpx; background: #f2f2fc; color: #111; font-size: 25rpx; line-height: 32rpx; }
.shift-slot { height: auto; min-height: 112rpx; padding: 10rpx 6rpx; overflow-wrap: anywhere; }
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
