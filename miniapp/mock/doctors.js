export const doctors = [
  {
    id: 1,
    name: '初淑芹',
    department: '耳鼻喉科',
    mockRanks: { satisfaction: 1, recommendation: 1 },
    visits: 9762,
    fee: 0,
    title: '主任',
    portrait: '/static/home/doctor-chu.jpg',
    credentials: ['中华医学会耳鼻喉科学会委员', '中国耳鼻喉微创治疗协会荣誉会员', '曾任职北京武警三院耳鼻喉科主任'],
    introduction: '各种耳鼻咽喉相关疾病的诊治，耳鸣耳聋、中耳炎、鼓膜穿孔、大疱鼓膜炎、耳石症、鼻炎、鼻窦炎、鼻出血、鼻息肉、鼻甲肥大、鼻中隔偏曲、鼻骨骨折等，急慢性咽炎、急慢性喉炎、扁桃体炎、扁桃体肿大、声带息肉、会厌囊肿、鼾症、腺样体肥大、鼻囊肿、鼻腔恶性肿瘤、鼻咽恶性肿瘤等耳鼻喉常见病、疑难病的诊断和治疗。',
    biography: '曾先后在广州中山大学附属医院、中国人民解放军总医院耳鼻喉诊疗中心进行学习深造，获得耳鼻喉最新诊疗的宝贵经验。',
  },
  {
    id: 2,
    name: '潘喜娥',
    department: '耳鼻喉科',
    mockRanks: { satisfaction: 2, recommendation: 2 },
    visits: 8792,
    fee: 10,
    title: '主任',
    portrait: '/static/home/doctor-pan.jpg',
    credentials: ['中华医学会耳鼻咽喉专业学会委员', '从事耳鼻喉科30余年', '曾任职北京武警三院耳鼻喉科主任'],
    introduction: '治疗各种原因引起的鼻炎、鼻窦炎、鼻息肉、鼻中隔偏曲、腺样体肥大、扁桃体炎、鼾症、咽喉炎、会厌炎、声带息肉小结白斑，喉癌、耳聋耳鸣、中耳炎、眩晕等耳鼻咽喉头颈外科常见病、多发病及疑难病症。',
    biography: '曾在北京、西安等地工作，致力于耳鼻喉临床诊疗，多次应邀出席国内耳鼻喉研究高峰论坛，在医学核心刊物上发表耳鼻喉学术论文多篇。',
  },
]

export function findDoctor(id) {
  return doctors.find(doctor => doctor.id === Number(id))
}
