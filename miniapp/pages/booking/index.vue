<script setup>
import { computed, ref } from 'vue'
import { onShow, onTabItemTap } from '@dcloudio/uni-app'
import { bookingMode as mode } from './booking-mode.js'
import DateStrip from './components/date_strip.vue'
import { openBooking } from '@/utils/booking-navigation.js'
import DoctorCard from './components/doctor_card.vue'
import { useBookingCalendar } from './booking-calendar.js'
import { bookingDepartments, bookingDoctors, directoryDemoMode } from '@/store/booking-directory.js'
import { configurationStatus } from '@/store/app-configuration.js'
import { handleTabShow, requestTabLogin } from '@/utils/guest-tab.js'

const modes = [
  { key: 'department', label: '按科室' },
  { key: 'date', label: '按日期' },
  { key: 'doctor', label: '按医生' },
]
const { schedule, selectedDay, scheduledDoctors, loadDay, refresh } = useBookingCalendar()
const doctorQuery = ref('')
const visibleDoctors = computed(() => {
  if (mode.value === 'date') return scheduledDoctors.value
  const query = doctorQuery.value.trim()
  return bookingDoctors.value.filter(doctor => doctor.name.includes(query))
})

onShow(() => {
  handleTabShow('/pages/booking/index')
  refresh()
})
onTabItemTap(() => requestTabLogin('/pages/booking/index'))
</script>

<template>
  <view class="booking-page">
    <view class="booking-header"><custom-page-header title="预约挂号" /></view>
    <view class="booking-content">
      <view class="filter-panel" :class="{ 'department-panel': mode === 'department' }">
        <view class="mode-tabs">
          <view v-for="item in modes" :key="item.key" class="mode-tab" :class="{ selected: mode === item.key }" @tap="mode = item.key">{{ item.label }}</view>
        </view>
        <template v-if="mode === 'department'">
          <view v-for="department in bookingDepartments" :key="department.id" class="department-row" aria-role="link"
            :style="department.depth ? { paddingLeft: (32 + Math.min(department.depth, 5) * 22) + 'rpx' } : null"
            @tap="openBooking('schedule', { department_id: department.id })">
            <view class="department-name">
              <image v-if="department.image_url" class="department-icon" :src="department.image_url" mode="aspectFit" aria-hidden="true" />
              <text v-else class="department-icon department-icon-text" aria-hidden="true">{{ department.icon || Array.from(department.name)[0] }}</text>
              <text>{{ department.name }}</text>
            </view>
            <view class="department-arrow" />
          </view>
          <view v-if="!bookingDepartments.length" class="empty-results" role="status">
            {{ configurationStatus === 'loading' ? '正在读取科室' : configurationStatus === 'error' ? '科室暂不可用' : '暂无科室' }}
          </view>
        </template>
        <view v-else-if="mode === 'doctor'" class="search-panel">
          <view class="search-field">
            <view class="search-glass" />
            <input v-model="doctorQuery" class="search-input" placeholder="请输入查询医生"
              placeholder-style="color: #bbb" aria-label="查询医生" />
            <view v-if="doctorQuery" class="search-clear" aria-role="button" aria-label="清空搜索" @tap="doctorQuery = ''">
              <icon type="clear" size="26rpx" color="#c5c5cc" />
            </view>
          </view>
        </view>
        <DateStrip v-if="mode === 'date'" :schedule="schedule" :selected="selectedDay?.date" @select="loadDay" />
      </view>
      <view v-if="mode === 'date' || mode === 'doctor'" class="doctor-list">
        <DoctorCard v-for="doctor in visibleDoctors" :key="mode === 'date' ? selectedDay.date + '-' + doctor.id : doctor.id"
          :doctor="doctor" :date="mode === 'date' ? selectedDay.date : ''" :demo="mode === 'date' || directoryDemoMode" />
        <view v-if="!visibleDoctors.length" class="empty-results" role="status">{{ mode === 'date' ? '当日暂无排班' : '未找到匹配的医生' }}</view>
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
.department-name { display: flex; align-items: center; gap: 16rpx; min-width: 0; padding-right: 18rpx; overflow-wrap: anywhere; }
.department-icon { flex: none; width: 48rpx; height: 48rpx; }
.department-icon-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #62a7db; text-align: center; line-height: 48rpx; }
.department-arrow { flex: none; width: 14rpx; height: 14rpx; border-top: 3rpx solid; border-right: 3rpx solid; transform: rotate(45deg); }
.search-panel { padding: 21rpx 20rpx; }
.search-field { display: flex; align-items: center; gap: 32rpx; padding: 0 18rpx; height: 62rpx; border-radius: 34rpx; color: #bbb; background: #f8f8f8; font-size: 25rpx; }
.search-glass { position: relative; box-sizing: border-box; width: 19rpx; height: 19rpx; border: 2rpx solid #c7c7c7; border-radius: 50%; }
.search-glass::after { content: ''; position: absolute; width: 10rpx; height: 3rpx; right: -7rpx; bottom: -3rpx; transform: rotate(45deg); background: #c7c7c7; }
.search-input { flex: 1; min-width: 0; height: 100%; color: #101010; font-size: 25rpx; }
.search-clear { display: flex; align-items: center; justify-content: flex-end; width: 48rpx; height: 100%; }
.doctor-list { padding-top: 2rpx; }
.empty-results { padding: 64rpx 24rpx; text-align: center; color: #536777; font-size: 26rpx; }
</style>
