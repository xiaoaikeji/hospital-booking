<script setup>
defineProps({ locked: Boolean, disabled: Boolean })

const name = defineModel('name', { type: String, default: '' })
const sex = defineModel('sex', { type: String, default: '' })
const age = defineModel('age', { type: String, default: '' })
</script>

<template>
  <view>
    <view class="row"><view>姓名<text class="required">*</text></view>
      <input v-model="name" :disabled="locked || disabled" :maxlength="100" aria-label="就诊人姓名" placeholder="请输入就诊人姓名" />
    </view>
    <view class="row"><view>性别<text class="required">*</text></view>
      <text v-if="locked && sex === '未知'">未知</text>
      <radio-group v-else class="sex" aria-label="性别" @change="sex = $event.detail.value">
        <label v-for="value in ['男', '女']" :key="value"><radio :value="value" :disabled="locked || disabled" :checked="sex === value" color="#62b443" />{{ value }}</label>
      </radio-group>
    </view>
    <view class="row"><view>年龄<text class="required">*</text></view>
      <input v-model="age" :disabled="locked || disabled" type="number" :maxlength="3" aria-label="就诊人年龄" placeholder="请输入就诊人年龄" />
    </view>
  </view>
</template>

<style scoped lang="scss">
@use '../form-fields';

.sex, .sex label { display: flex; align-items: center; }
.sex { gap: 24rpx; }
.sex radio { transform: scale(.85); }
</style>
