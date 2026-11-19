<script setup>
import { doctors } from '@/mock/doctors.js'
import { clinics, entries } from '../home-first-mock.js'

const { statusBarHeight, windowWidth } = uni.getWindowInfo()
const capsule = uni.getMenuButtonBoundingClientRect()
const hasCapsule = capsule.height > 0 && capsule.top >= statusBarHeight
const navigationHeight = hasCapsule ? capsule.height + 2 * (capsule.top - statusBarHeight) : 44
const titleSpace = hasCapsule ? capsule.left - 4 : windowWidth - 88
</script>

<template>
  <view class="home-page">
    <view class="home-navigation" :style="{ paddingTop: statusBarHeight + 'px' }">
      <view class="navigation-row" :style="{ height: navigationHeight + 'px', width: titleSpace + 'px' }">
        <text class="navigation-title">临汾西京眼耳鼻喉医院预约挂号</text>
      </view>
    </view>
    <view class="home-content">
      <view class="home-banner">
        <image class="banner-art" src="/static/home/registration-banner.jpg" mode="scaleToFill" aria-label="预约挂号智慧平台，线上预约，快速便捷" />
        <view class="banner-dot" />
      </view>

      <view class="home-entries">
        <view v-for="entry in entries" :key="entry.id" class="entry-card" :class="'entry-' + entry.id">
          <text class="entry-title">{{ entry.title }}</text>
          <text class="entry-description">{{ entry.description }}</text>
          <image class="entry-icon" :src="'/static/home/' + entry.id + '.svg'" mode="aspectFit" />
        </view>
      </view>

      <view class="clinics-section">
        <text class="section-title">专病门诊</text>
        <view class="clinic-grid">
          <view v-for="clinic in clinics" :key="clinic.icon" class="clinic-item">
            <image class="clinic-icon" :src="'/static/home/' + clinic.icon + '.svg'" mode="aspectFit" />
            <text class="clinic-name">{{ clinic.name }}</text>
          </view>
        </view>
      </view>

      <view class="doctors-section">
        <view class="doctors-heading">
          <text class="section-title">医生推荐</text>
          <text class="doctors-more">更多</text>
        </view>
        <view class="doctor-list">
          <view v-for="doctor in doctors" :key="doctor.name" class="doctor-row">
            <image class="doctor-portrait" :src="doctor.portrait" mode="aspectFill" :aria-label="doctor.name" />
            <view class="doctor-info">
              <view class="doctor-heading">
                <text class="doctor-name">{{ doctor.name }}</text>
                <text class="doctor-title">{{ doctor.title }}</text>
              </view>
              <text class="doctor-description">{{ doctor.introduction }}</text>
            </view>
          </view>
        </view>
      </view>
    </view>

  </view>
</template>

<style lang="scss" scoped>
.home-page {
  color: #111;
  background: #fff;
}
.home-navigation { position: sticky; z-index: 1; top: 0; background: #f8f8f8; border-bottom: 1rpx solid #f8f8f8; }
.navigation-row { display: flex; align-items: center; justify-content: flex-end; }
.navigation-title {
  max-width: calc(100% - 12rpx);
  margin-right: max(0px, calc(100% - 50vw - 7em));
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 30rpx;
  font-weight: 600;
  line-height: 1.4;
}
.home-content { padding: 0 22rpx; }
.home-banner {
  position: relative;
  height: 224rpx;
  overflow: hidden;
  border-radius: 17rpx;
  background: #61bfbd;
}
.banner-art { display: block; width: 100%; height: 100%; }
.banner-dot {
  position: absolute;
  left: 50%;
  bottom: 17rpx;
  width: 14rpx;
  height: 14rpx;
  transform: translateX(-50%);
  border-radius: 50%;
  background: #fff;
}
.home-entries {
  display: grid;
  grid-template-columns: 356fr 328fr;
  grid-template-rows: repeat(2, 129rpx);
  gap: 18rpx 22rpx;
  margin-top: 30rpx;
}
.entry-card {
  position: relative;
  overflow: hidden;
  padding: 22rpx 0 0 30rpx;
  box-sizing: border-box;
  border-radius: 17rpx;
}
.entry-title, .entry-description { display: block; }
.entry-title { color: #101010; font-size: 28rpx; line-height: 40rpx; }
.entry-description { margin-top: 18rpx; color: #a1a8aa; font-size: 22rpx; line-height: 31rpx; }
.entry-icon { position: absolute; right: 15rpx; bottom: 22rpx; width: 76rpx; height: 66rpx; }
.entry-registration {
  grid-row: span 2;
  padding-top: 28rpx;
  background: #edf6fc;
  .entry-description { font-size: 24rpx; margin-top: 18rpx; }
  .entry-icon { width: 103rpx; height: 103rpx; right: 24rpx; bottom: 30rpx; }
}
.entry-appointment {
  background: #eefbfd;
  .entry-icon { width: 69rpx; height: 66rpx; right: 21rpx; bottom: 22rpx; }
}
.entry-experts { background: #fdfaf3; }
.clinics-section { margin-top: 32rpx; }
.section-title { display: block; padding-left: 22rpx; font-size: 28rpx; line-height: 42rpx; }
.clinic-grid { display: grid; grid-template-columns: repeat(4, 1fr); margin-top: 19rpx; }
.clinic-item { display: flex; flex-direction: column; align-items: center; justify-content: flex-start; height: 143rpx; }
.clinic-icon { width: 61rpx; height: 61rpx; margin-top: 9rpx; }
.clinic-name { margin-top: 14rpx; font-size: 24rpx; line-height: 38rpx; }
.doctors-section { margin-top: 14rpx; }
.doctors-heading { display: flex; align-items: center; justify-content: space-between; }
.doctors-more { color: #999; font-size: 21rpx; line-height: 36rpx; padding-right: 8rpx; }
.doctor-list { margin-top: 42rpx; }
.doctor-row { display: flex; align-items: flex-start; gap: 16rpx; min-height: 156rpx; }
.doctor-portrait { flex: none; display: block; width: 100rpx; height: 100rpx; border-radius: 50%; }
.doctor-info { flex: 1; min-width: 0; }
.doctor-heading { display: flex; align-items: baseline; gap: 20rpx; line-height: 46rpx; }
.doctor-name { color: #101010; font-size: 30rpx; }
.doctor-title { color: #666; font-size: 25rpx; }
.doctor-description {
  display: -webkit-box;
  overflow: hidden;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  margin-top: 5rpx;
  color: #777;
  font-size: 24rpx;
  font-weight: 300;
  line-height: 33rpx;
}
</style>
