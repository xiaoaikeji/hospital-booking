<script setup>
import { computed, reactive, ref } from 'vue'
import DoctorCard from './components/doctor_card.vue'
import { doctors } from '@/mock/doctors.js'

const filters = {
  department: [{ label: '全部科室', value: '' }, { label: '耳鼻喉科', value: '耳鼻喉科' }],
  sort: [
    { label: '综合排序', value: '' }, { label: '满意度', value: 'satisfaction' },
    { label: '接诊量', value: 'visits' }, { label: '推荐度', value: 'recommendation' },
  ],
}
const selection = reactive({ department: filters.department[0], sort: filters.sort[0] })
const openFilter = ref('')
const filteredDoctors = computed(() => {
  const department = selection.department.value
  const result = doctors.filter(doctor => !department || doctor.department === department)
  const sort = selection.sort.value
  if (sort) result.sort((a, b) => a.mockRanks[sort] - b.mockRanks[sort])
  return result
})

function selectOption(option) {
  selection[openFilter.value] = option
  openFilter.value = ''
}
</script>

<template>
  <view class="doctors-page">
    <view class="doctor-toolbar">
      <custom-page-header title="医生" back />
      <view class="doctor-filters">
        <view v-for="(selected, key) in selection" :key="key" class="filter-label" aria-role="button"
          @tap="openFilter = openFilter === key ? '' : key">
          {{ selected.label }}<view class="filter-arrow" :class="{ raised: openFilter === key }" />
        </view>
      </view>
      <view v-if="openFilter" class="filter-menu">
        <view v-for="option in filters[openFilter]" :key="option.label" class="filter-option"
          :class="{ selected: selection[openFilter].value === option.value }" @tap="selectOption(option)">
          <text>{{ option.label }}</text>
          <icon v-if="selection[openFilter].value === option.value" type="success_no_circle" size="22rpx" color="#66a9d8" />
        </view>
      </view>
    </view>
    <view v-if="openFilter" class="filter-backdrop" aria-label="收起筛选" @tap="openFilter = ''" @touchmove.stop.prevent />
    <view class="doctor-results">
      <navigator v-for="doctor in filteredDoctors" :key="doctor.id" url="/pages/ucenter/login" hover-class="none"
        :aria-label="'预约' + doctor.name">
        <DoctorCard :doctor="doctor" />
      </navigator>
    </view>
  </view>
</template>

<style scoped>
.doctors-page { display: flex; flex-direction: column; min-height: 100vh; background: #fff; }
.doctor-toolbar { position: sticky; top: 0; z-index: 2; background: #fff; }
.doctor-filters { display: flex; height: 80rpx; }
.filter-label { flex: 1; display: flex; align-items: center; justify-content: center; gap: 8rpx; color: #111; font-size: 28rpx; }
.filter-arrow { width: 11rpx; height: 11rpx; margin-top: -6rpx; border-right: 2rpx solid; border-bottom: 2rpx solid; transform: rotate(45deg); }
.filter-arrow.raised { margin-top: 6rpx; transform: rotate(225deg); }
.filter-backdrop { position: fixed; z-index: 1; inset: 0; background: rgba(0,0,0,.40); }
.filter-menu { position: absolute; top: 100%; left: 0; right: 0; background: #fff; }
.filter-option { box-sizing: border-box; display: flex; justify-content: space-between; align-items: center; height: 101rpx; padding: 0 32rpx; border-top: 1rpx solid #eee; color: #111; font-size: 28rpx; }
.filter-option.selected { color: #66a9d8; }
.doctor-results { flex: 1; padding: 12rpx 32rpx 32rpx; background: linear-gradient(180deg, #71b3e7, #f4f4f6 75%); }
</style>
