<script setup>
import { computed } from 'vue'
import { directoryDemoMode, homepageDoctors as doctors } from '@/store/booking-directory.js'
import { bookingMode } from '@/pages/booking/booking-mode.js'
import { switchFromHomeCard } from '@/utils/guest-tab.js'
import { openBooking } from '@/utils/booking-navigation.js'
import { clinics } from '@/mock/clinics.js'
import { appName, hospitalProfile, pageLinks } from '@/store/app-configuration.js'
import { callHospital } from '@/utils/call-hospital.js'
import { entries } from '../home-first-mock.js'

const banners = computed(() => pageLinks.value.home_banner)
const homePhone = computed(() => hospitalProfile.value.show_phone_on_homepage ? hospitalProfile.value.mobile : '')

const { statusBarHeight, windowWidth } = uni.getWindowInfo()
const capsule = uni.getMenuButtonBoundingClientRect()
const hasCapsule = capsule.height > 0 && capsule.top >= statusBarHeight
const navigationHeight = hasCapsule ? capsule.height + 2 * (capsule.top - statusBarHeight) : 44
const titleSpace = hasCapsule ? capsule.left - 4 : windowWidth - 88

function openEntry(entry) {
  if (entry.id === 'registration') {
    bookingMode.value = 'department'
    switchFromHomeCard(entry.url)
    return
  }
  uni.navigateTo({ url: entry.url })
}
</script>

<template>
  <view class="home-page">
    <view class="home-navigation" :style="{ paddingTop: statusBarHeight + 'px' }">
      <view class="navigation-row" :style="{ height: navigationHeight + 'px', width: titleSpace + 'px' }">
        <text class="navigation-title">{{ appName }}</text>
      </view>
    </view>
    <view class="home-content">
      <view v-if="banners.length" class="home-banner">
        <swiper class="banner-swiper" :indicator-dots="banners.length > 1" indicator-active-color="#fff"
          :autoplay="banners.length > 1" :circular="banners.length > 1" :interval="5000">
          <swiper-item v-for="banner in banners" :key="banner.id">
            <custom-page-link :link="banner">
              <image class="banner-art" :src="banner.image_url" mode="scaleToFill" :aria-label="banner.name" />
            </custom-page-link>
          </swiper-item>
        </swiper>
        <view v-if="banners.length === 1" class="banner-dot" />
      </view>

      <view v-if="hospitalProfile.announcement" class="home-announcement">
        <text class="announcement-title">医院公告</text>
        <view class="announcement-text">{{ hospitalProfile.announcement }}</view>
      </view>

      <view class="home-entries">
        <view v-for="entry in entries" :key="entry.id" class="entry-card" :class="'entry-' + entry.id"
          role="link" :aria-label="entry.title" @tap="openEntry(entry)">
          <text class="entry-title">{{ entry.title }}</text>
          <text class="entry-description">{{ entry.description }}</text>
          <image class="entry-icon" :src="'/static/home/' + entry.id + '.svg'" mode="aspectFit" />
        </view>
      </view>

      <button v-if="homePhone" class="home-phone" hover-class="none" :aria-label="'拨打医院电话 ' + homePhone"
        @tap="callHospital(homePhone)">
        <text>联系电话</text><text class="phone-number">{{ homePhone }}</text>
      </button>

      <view class="clinics-section">
        <text class="section-title">专病门诊</text>
        <view class="clinic-grid">
          <view v-for="clinic in clinics" :key="clinic.icon" class="clinic-item"
            aria-role="link" :aria-label="clinic.name" @tap="openBooking('schedule', { clinic: clinic.icon })">
            <image class="clinic-icon" :src="'/static/home/' + clinic.icon + '.svg'" mode="aspectFit" />
            <text class="clinic-name">{{ clinic.name }}</text>
          </view>
        </view>
      </view>

      <view class="doctors-section">
        <view class="doctors-heading">
          <text class="section-title">医生推荐</text>
          <navigator class="doctors-more" url="/pages/booking/doctors" hover-class="none" aria-label="更多医生">更多</navigator>
        </view>
        <view class="doctor-list">
          <view v-for="doctor in doctors" :key="doctor.id" class="doctor-row"
            aria-role="link" :aria-label="doctor.name" @tap="openBooking('doctor', { id: doctor.id, demo: directoryDemoMode })">
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
.navigation-row { display: flex; align-items: center; }
.navigation-row::before, .navigation-row::after { content: ''; flex: 1 1 0%; }
/* 给左侧留出与微信胶囊等宽的空间，长标题可向左延伸。 */
.navigation-row::before { flex-basis: calc(100vw - 100%); }
.navigation-title {
  flex: none;
  max-width: calc(100% - 12rpx);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 30rpx;
  font-weight: 600;
  line-height: 1.4;
}
.home-content { padding: 22rpx 22rpx 0; }
.home-banner {
  position: relative;
  height: 224rpx;
  overflow: hidden;
  border-radius: 17rpx;
  background: #61bfbd;
}
.banner-swiper, .banner-art { display: block; width: 100%; height: 100%; }
.banner-dot {
  pointer-events: none;
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
}
.home-banner + .home-entries { margin-top: 30rpx; }
.home-banner + .home-announcement { margin-top: 20rpx; }
.home-announcement { margin-bottom: 20rpx; padding: 18rpx 22rpx; border-radius: 17rpx; background: #edf6fc; }
.announcement-title { font-size: 28rpx; font-weight: 600; line-height: 40rpx; }
.announcement-text { margin-top: 6rpx; color: #333; font-size: 26rpx; line-height: 39rpx; white-space: pre-wrap; overflow-wrap: anywhere; }
.home-phone { display: flex; align-items: center; justify-content: space-between; gap: 16rpx; margin: 18rpx 0 0; padding: 15rpx 22rpx; border-radius: 17rpx; background: #edf6fc; color: #111; font-size: 28rpx; line-height: 40rpx; text-align: left; }
.home-phone::after { border: 0; }
.phone-number { min-width: 0; color: #2877b7; overflow-wrap: anywhere; }
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
