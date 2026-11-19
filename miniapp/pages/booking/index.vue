<script setup>
import { computed, ref } from 'vue'
import { onShow } from '@dcloudio/uni-app'
import { bookingMode as mode } from './booking-mode.js'
import DoctorCard from './components/doctor_card.vue'
import { getBookingSchedule } from '@/mock/booking-schedule.js'
import { doctors } from '@/mock/doctors.js'

const modes = [
  { key: 'department', label: '按科室' },
  { key: 'date', label: '按日期' },
  { key: 'doctor', label: '按医生' },
]
const schedule = ref([])
const selectedDay = ref(null)
const scheduledDoctors = computed(() => doctors.filter(doctor => selectedDay.value?.doctorIds.includes(doctor.id)))

onShow(() => {
  schedule.value = getBookingSchedule()
  selectedDay.value = schedule.value.find(day => day.date === selectedDay.value?.date) ?? schedule.value[0]
})
</script>

<template>
  <view class="booking-page">
    <view class="booking-header"><custom-page-header title="预约挂号" /></view>
    <view class="booking-content">
      <view class="filter-panel" :class="{ 'department-panel': mode === 'department' }">
        <view class="mode-tabs">
          <view v-for="item in modes" :key="item.key" class="mode-tab" :class="{ selected: mode === item.key }" @tap="mode = item.key">{{ item.label }}</view>
        </view>
        <navigator v-if="mode === 'department'" class="department-row" url="/pages/ucenter/login" hover-class="none">
          <text>耳鼻喉科</text><view class="department-arrow" />
        </navigator>
        <view v-else-if="mode === 'doctor'" class="search-panel">
          <view class="search-field"><view class="search-glass" /><text>请输入查询医生</text></view>
        </view>
        <scroll-view v-show="mode === 'date'" scroll-x class="date-strip" :show-scrollbar="false">
          <view class="date-options">
            <view v-for="item in schedule" :key="item.date" class="date-option"
              :class="{ 'date-selected': item.date === selectedDay?.date }" role="button" @tap="selectedDay = item">
              <text>{{ item.weekday }}</text><text class="calendar-date">{{ item.label }}</text>
            </view>
          </view>
        </scroll-view>
      </view>
      <view v-if="mode === 'date'" class="doctor-list">
        <navigator v-for="doctor in scheduledDoctors" :key="doctor.id" url="/pages/ucenter/login"
          hover-class="none" :aria-label="'预约' + doctor.name">
          <DoctorCard :doctor="doctor" />
        </navigator>
      </view>
      <view v-else-if="mode === 'doctor'" class="doctor-list">
        <DoctorCard v-for="doctor in doctors" :key="doctor.id" :doctor="doctor" />
      </view>
    </view>
  </view>
</template>

<style scoped>
.booking-page { min-height: 100vh; display: flex; flex-direction: column; color: #101010; }
.booking-header { background: #fff; }
.booking-content { flex: 1; display: flex; flex-direction: column; padding: 32rpx 32rpx 50rpx; background: linear-gradient(180deg,#99c9f1 0%,#f4f4f6 78%); }
.filter-panel { overflow: hidden; border-radius: 18rpx; background: #fff; }
.department-panel { flex: 1; }
.mode-tabs { display: flex; background: #d9eaf8; }
.mode-tab { flex: 1; text-align: center; color: #62a7db; font-size: 29rpx; line-height: 81rpx; }
.mode-tab.selected { border-radius: 16rpx 16rpx 0 0; color: #fff; background: linear-gradient(90deg,#73b4ee,#8ac2ee); }
.department-row { display: flex; align-items: center; justify-content: space-between; padding: 0 40rpx 0 32rpx; height: 128rpx; font-size: 30rpx; }
.department-arrow { width: 14rpx; height: 14rpx; border-top: 3rpx solid; border-right: 3rpx solid; transform: rotate(45deg); }
.search-panel { padding: 21rpx 20rpx; }
.search-field { display: flex; align-items: center; gap: 32rpx; padding: 0 18rpx; height: 62rpx; border-radius: 34rpx; color: #bbb; background: #f8f8f8; font-size: 25rpx; }
.search-glass { position: relative; box-sizing: border-box; width: 19rpx; height: 19rpx; border: 2rpx solid #c7c7c7; border-radius: 50%; }
.search-glass::after { content: ''; position: absolute; width: 10rpx; height: 3rpx; right: -7rpx; bottom: -3rpx; transform: rotate(45deg); background: #c7c7c7; }
.date-strip { width: 100%; white-space: nowrap; }
.date-options { display: inline-flex; width: max-content; gap: 20rpx; padding: 22rpx 20rpx 25rpx; vertical-align: top; }
.date-option { flex: none; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4rpx; width: 98rpx; height: 100rpx; border-radius: 8rpx; background: #f5f4fa; font-size: 26rpx; line-height: 36rpx; }
.date-selected { background: #5da8e4; color: #fff; }
.calendar-date { font-size: 22rpx; font-weight: 300; line-height: 30rpx; }
.doctor-list { padding-top: 2rpx; }
</style>
