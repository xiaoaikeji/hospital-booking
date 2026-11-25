<script setup>
import { computed, ref } from 'vue'
import { onLoad, onShow } from '@dcloudio/uni-app'
import { clinics } from '@/mock/clinics.js'
import { canOpenBooking } from '@/utils/booking-navigation.js'
import { scheduleMessage, shiftLabels, useBookingCalendar } from './booking-calendar.js'
import DateStrip from './components/date_strip.vue'
import DoctorCard from './components/doctor_card.vue'
import { bookingDepartments, directoryDemoMode } from '@/store/booking-directory.js'
import { checkAppAccess } from '@/utils/app-access.js'

const clinic = ref(null)
const departmentId = ref('')
const ready = ref(false)
const fromDemo = computed(() => directoryDemoMode || !departmentId.value)
const { schedule, selectedDay, scheduledDoctors, loadDay, refresh } = useBookingCalendar(() => fromDemo.value)
const department = computed(() => departmentId.value && bookingDepartments.value.find(entry => entry.id === departmentId.value))
const title = computed(() => departmentId.value ? department.value?.name || '科室医生' : clinic.value?.name || '耳鼻喉科')
const visibleDoctors = computed(() => {
  if (!ready.value) return []
  if (fromDemo.value) return scheduledDoctors.value
  return department.value ? scheduledDoctors.value.filter(doctor => doctor.department_ids.includes(departmentId.value)) : []
})

onLoad(async options => {
  departmentId.value = options.department_id || ''
  if (!await canOpenBooking('schedule', options)) return
  clinic.value = clinics.find(item => item.icon === options.clinic)
  refresh()
  ready.value = true
})
onShow(() => {
  refresh()
  if (ready.value && !fromDemo.value) checkAppAccess()
})
</script>

<template>
  <view class="schedule-page">
    <view class="schedule-header">
      <custom-page-header :title="title" back />
      <DateStrip :schedule="schedule" :selected="selectedDay?.date" compact @select="loadDay" />
    </view>
    <view class="schedule-results">
      <DoctorCard v-for="doctor in visibleDoctors" :key="doctor.id"
        :doctor="doctor" :date="selectedDay?.date || ''" :department="!clinic && !departmentId"
        :department-id="departmentId" :demo="fromDemo" :shifts="shiftLabels(selectedDay, doctor.id)" />
      <view v-if="ready && !visibleDoctors.length" class="empty-results" role="status">
        {{ fromDemo ? '当日暂无排班' : (schedule.length && !department ? '暂无该科室信息' : scheduleMessage) }}
      </view>
    </view>
  </view>
</template>

<style scoped>
.schedule-page { min-height: 100vh; display: flex; flex-direction: column; color: #101010; }
.schedule-header { position: sticky; z-index: 1; top: 0; background: #fff; }
.schedule-results { flex: 1; padding: 12rpx 32rpx 32rpx; background: linear-gradient(180deg,#a4cff1,#f4f4f6 69%); }
.empty-results { padding: 64rpx 24rpx; text-align: center; color: #536777; font-size: 26rpx; }
</style>
