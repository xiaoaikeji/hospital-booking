<script setup>
import DoctorCard from './components/doctor_card.vue'
import { doctors } from '@/mock/doctors.js'
</script>

<template>
  <view class="doctors-page">
    <custom-page-header title="医生" back />
    <view class="doctor-filters">
      <view class="filter-label">全部科室<view class="filter-arrow" /></view>
      <view class="filter-label">综合排序<view class="filter-arrow" /></view>
    </view>
    <view class="doctor-results">
      <DoctorCard v-for="doctor in doctors" :key="doctor.name" :doctor="doctor" />
    </view>
  </view>
</template>

<style scoped>
.doctors-page { display: flex; flex-direction: column; min-height: 100vh; background: #fff; }
.doctor-filters { display: flex; height: 80rpx; }
.filter-label { flex: 1; display: flex; align-items: center; justify-content: center; gap: 8rpx; color: #111; font-size: 28rpx; }
.filter-arrow { width: 11rpx; height: 11rpx; margin-top: -6rpx; border-right: 2rpx solid; border-bottom: 2rpx solid; transform: rotate(45deg); }
.doctor-results { flex: 1; padding: 12rpx 32rpx 32rpx; background: linear-gradient(180deg, #71b3e7, #f4f4f6 75%); }
</style>
