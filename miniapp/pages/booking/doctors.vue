<script setup>
import { computed, reactive, ref } from 'vue'
import { onLoad, onShow } from '@dcloudio/uni-app'
import DoctorCard from './components/doctor_card.vue'
import { useDoctorList } from './doctor-list.js'
import { bookingDepartments, bookingDoctors, directoryDemoMode } from '@/store/booking-directory.js'
import { checkAppAccess } from '@/utils/app-access.js'

const defaultSort = { label: '综合排序', value: '' }
const demoSorts = [
  defaultSort, { label: '满意度', value: 'satisfaction' },
  { label: '接诊量', value: 'visits' }, { label: '推荐度', value: 'recommendation' },
]
const feeSorts = [
  defaultSort, { label: '挂号费从低到高', value: 'fee_asc' }, { label: '挂号费从高到低', value: 'fee_desc' },
]
const filters = computed(() => {
  const department = [{ label: '全部科室', value: '' }, ...bookingDepartments.value.map(item => ({
    label: item.name, value: directoryDemoMode ? item.name : item.id,
  }))]
  return { department, sort: directoryDemoMode ? demoSorts : feeSorts }
})
const selection = reactive({ department: '', sort: '' })
const doctorQuery = ref('')
const openFilter = ref('')
const selected = key => filters.value[key].find(option => option.value === selection[key]) ?? filters.value[key][0]
const department = computed(() => selected('department').value)
const query = computed(() => directoryDemoMode ? null : { q: doctorQuery.value, department_id: department.value, sort: selection.sort })
const { doctors, status, refresh } = useDoctorList(query)

const filteredDoctors = computed(() => {
  if (!directoryDemoMode) return doctors.value
  const result = bookingDoctors.value.filter(doctor =>
    (!department.value || doctor.department === department.value) && doctor.name.includes(doctorQuery.value))
  const sort = selection.sort
  if (sort === 'visits') result.sort((a, b) => b.visits - a.visits)
  else if (sort) result.sort((a, b) => a.mockRanks[sort] - b.mockRanks[sort])
  return result
})

function selectOption(option) {
  const key = openFilter.value
  if (selection[key] !== option.value) {
    selection[key] = option.value
    uni.pageScrollTo({ scrollTop: 0, duration: 0 })
  }
  openFilter.value = ''
}
onLoad(({ q = '' }) => {
  if (typeof q !== 'string') return

  try {
    doctorQuery.value = decodeURIComponent(q).trim()
  } catch {
    doctorQuery.value = q.trim()
  }
})
onShow(checkAppAccess)
</script>

<template>
  <view class="doctors-page">
    <view class="doctor-toolbar">
      <custom-page-header title="医生" back />
      <view class="doctor-filters">
        <view v-for="(options, key) in filters" :key="key" class="filter-label" aria-role="button"
          @tap="openFilter = openFilter === key ? '' : key">
          {{ selected(key).label }}<view class="filter-arrow" :class="{ raised: openFilter === key }" />
        </view>
      </view>
      <view v-if="openFilter" class="filter-menu">
        <view v-for="option in filters[openFilter]" :key="option.value" class="filter-option"
          :class="{ selected: selected(openFilter).value === option.value }" @tap="selectOption(option)">
          <text>{{ option.label }}</text>
          <icon v-if="selected(openFilter).value === option.value" type="success_no_circle" size="22rpx" color="#66a9d8" />
        </view>
      </view>
    </view>
    <view v-if="openFilter" class="filter-backdrop" aria-label="收起筛选" @tap="openFilter = ''" @touchmove.stop.prevent />
    <view class="doctor-results">
      <DoctorCard v-for="doctor in filteredDoctors" :key="doctor.id" :doctor="doctor" :demo="directoryDemoMode"
        :department-id="directoryDemoMode ? '' : department" />
      <view v-if="!directoryDemoMode && status === 'error'" class="empty-results" aria-role="button" @tap="refresh()">医生资料暂不可用，点击重试</view>
      <view v-else-if="!filteredDoctors.length" class="empty-results" role="status">
        {{ !directoryDemoMode && status === 'loading' ? '正在读取医生资料' : '暂无医生' }}
      </view>
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
.empty-results { padding-top: 64rpx; text-align: center; color: #536777; font-size: 26rpx; }
</style>
