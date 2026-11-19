const homeAssets = '/static/home/'

export const entries = [
  { id: 'registration', title: '预约挂号', description: '线上预约,快速便捷' },
  { id: 'appointment', title: '我的预约', description: '查看个人预约' },
  { id: 'experts', title: '专家团队', description: '按医生预约挂号' },
]

export const clinics = [
  { name: '扁桃体炎', icon: 'tonsils' },
  { name: '咽喉炎', icon: 'pharyngitis' },
  { name: '耳鸣耳聋', icon: 'tinnitus' },
  { name: '听力下降', icon: 'hearing-loss' },
  { name: '中耳炎', icon: 'otitis' },
  { name: '鼻息肉', icon: 'nasal-polyps' },
  { name: '鼻窦炎', icon: 'sinusitis' },
  { name: '各类鼻炎', icon: 'rhinitis' },
]

export const doctors = [
  {
    name: '初淑芹',
    title: '主任',
    portrait: homeAssets + 'doctor-chu.jpg',
    introduction: '各种耳鼻咽喉相关疾病的诊治，耳鸣耳聋、中耳炎、鼓膜穿孔、大疱鼓膜炎、耳石症、鼻炎、鼻窦炎、鼻出血、鼻息…',
  },
  {
    name: '潘喜娥',
    title: '主任',
    portrait: homeAssets + 'doctor-pan.jpg',
    introduction: '治疗各种原因引起的鼻炎、鼻窦炎、鼻息肉、鼻中隔偏曲、腺样体肥大、扁桃体炎、鼾症、咽喉炎、会厌炎、声带息…',
  },
]

export const tabs = [
  { label: '首页', icon: 'home-active.png' },
  { label: '预约挂号', icon: 'booking.svg' },
  { label: '我的', icon: 'profile.png' },
]
