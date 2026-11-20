// 原图坐标用于画布、拖拽和导出；与扫码目标、微信请求分离。
window.BookingPosterLayout = {
  box(canvas, values) {
    const [x, y, size] = values.map(Number);
    if (![x, y, size].every(Number.isInteger) || x < 0 || y < 0 || size <= 0 || x + size > canvas.width || y + size > canvas.height) {
      throw new Error("请把二维码完整放在底图内，位置和边长使用整数像素。");
    }
    return { x, y, size };
  },
  draw(canvas, background, code, box) {
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(background, 0, 0, canvas.width, canvas.height);
    if (code && box) {
      ctx.fillStyle = "white";
      ctx.fillRect(box.x, box.y, box.size, box.size);
      ctx.drawImage(code, box.x, box.y, box.size, box.size);
    }
  },
  image(src) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error("图片加载失败，请重试。"));
      image.src = src;
    });
  }
};
