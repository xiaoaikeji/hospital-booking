// 模拟请求耗时，同时验证本次选择的临时图片仍可读取。反馈内容只在当前页面使用。
export async function submitFeedback({ message, images }) {
  if (!message.trim()) throw new Error('请填写反馈内容')
  await Promise.all([
    new Promise(resolve => setTimeout(resolve, 450)),
    ...images.map(src => uni.getImageInfo({ src })),
  ])
}
