<script setup>
import { ref } from 'vue'
import { onLoad, onShow } from '@dcloudio/uni-app'
import { clinics } from '@/mock/clinics.js'
import { canOpenBooking } from '@/utils/booking-navigation.js'
import { useBookingCalendar } from './booking-calendar.js'
import DateStrip from './components/date_strip.vue'
import DoctorCard from './components/doctor_card.vue'

const clinic = ref(null)
const { schedule, selectedDay, scheduledDoctors, loadDay, refresh } = useBookingCalendar()

onLoad(options => {
  if (!canOpenBooking('schedule', options)) return
  clinic.value = clinics.find(item => item.icon === options.clinic)
})
onShow(refresh)
</script>

<template>
  <view class="schedule-page">
    <view class="schedule-header">
      <custom-page-header :title="clinic?.name || '耳鼻喉科'" back />
      <DateStrip :schedule="schedule" :selected="selectedDay?.date" compact @select="loadDay" />
    </view>
    <view class="schedule-results">
      <DoctorCard v-for="doctor in scheduledDoctors" :key="selectedDay.date + '-' + doctor.id"
        :doctor="doctor" :date="selectedDay.date" :department="!clinic" />
    </view>
  </view>
</template>

<style scoped>
.schedule-page { min-height: 100vh; display: flex; flex-direction: column; color: #101010; }
.schedule-header { position: sticky; z-index: 1; top: 0; background: #fff; }
.schedule-results { flex: 1; padding: 12rpx 32rpx 32rpx; background: linear-gradient(180deg,#a4cff1,#f4f4f6 69%); }
</style>
