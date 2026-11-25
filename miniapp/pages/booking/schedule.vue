<script setup>
import { computed, ref } from 'vue'
import { onLoad, onShow } from '@dcloudio/uni-app'
import { clinics } from '@/mock/clinics.js'
import { canOpenBooking } from '@/utils/booking-navigation.js'
import { useBookingCalendar } from './booking-calendar.js'
import DateStrip from './components/date_strip.vue'
import DoctorCard from './components/doctor_card.vue'
import { bookingDepartments, bookingDoctors } from '@/store/booking-directory.js'
import { checkAppAccess } from '@/utils/app-access.js'

const clinic = ref(null)
const departmentId = ref('')
const ready = ref(false)
const { schedule, selectedDay, scheduledDoctors, loadDay, refresh } = useBookingCalendar()
const department = computed(() => departmentId.value && bookingDepartments.value.find(entry => entry.id === departmentId.value))
const title = computed(() => departmentId.value ? department.value?.name || '科室医生' : clinic.value?.name || '耳鼻喉科')
const visibleDoctors = computed(() => {
  if (!ready.value) return []
  if (!departmentId.value) return scheduledDoctors.value
  return department.value ? bookingDoctors.value.filter(doctor => doctor.department_ids.includes(departmentId.value)) : []
})

onLoad(async options => {
  departmentId.value = options.department_id || ''
  if (!await canOpenBooking('schedule', options)) return
  clinic.value = clinics.find(item => item.icon === options.clinic)
  ready.value = true
})
onShow(() => {
  refresh()
  if (ready.value && departmentId.value) checkAppAccess()
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
        :department-id="departmentId" :demo="!departmentId" />
      <view v-if="ready && !visibleDoctors.length" class="empty-results" role="status">
        {{ departmentId ? (department ? '该科室暂无医生' : '暂无该科室信息') : '当日暂无排班' }}
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
