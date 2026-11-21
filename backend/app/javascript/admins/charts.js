document.addEventListener("DOMContentLoaded", () => {
  if (!window.ApexCharts) return;
  const theme = document.documentElement;
  const charts = [...document.querySelectorAll("[data-admin-chart]")].map(element => {
    const { type, categories, series } = JSON.parse(element.dataset.adminChart);
    const style = () => {
      const css = getComputedStyle(theme);
      return {
        colors: series.map(item => css.getPropertyValue("--tblr-" + item.color).trim()),
        grid: { borderColor: css.getPropertyValue("--tblr-border-color").trim(), strokeDashArray: 3 },
        theme: { mode: theme.dataset.bsTheme === "dark" ? "dark" : "light" }
      };
    };
    const step = Math.max(1, Math.ceil(categories.length / 6));
    const ticks = new Set(categories.filter((_, index) => index % step === 0));
    const peak = Math.max(1, ...series.flatMap(item => item.data));
    const yStep = Math.ceil(peak / 4);
    const yTicks = Math.ceil(peak / yStep);
    const chart = new window.ApexCharts(element, {
      ...style(),
      series: series.map(({ name, data }) => ({ name, data })),
      chart: { type, height: 195, background: "transparent", fontFamily: "inherit", parentHeightOffset: 0,
        toolbar: { show: false }, animations: { enabled: false }, zoom: { enabled: false } },
      dataLabels: { enabled: false },
      legend: { show: false },
      stroke: { curve: "straight", width: type === "area" ? 2 : 0 },
      fill: type === "area" ? { type: "gradient", gradient: { shadeIntensity: 0, opacityFrom: 0.24, opacityTo: 0.04, stops: [0, 100] } } : { opacity: 1 },
      plotOptions: { bar: { columnWidth: "65%", borderRadius: 2 } },
      yaxis: { min: 0, max: yTicks * yStep, tickAmount: yTicks, decimalsInFloat: 0 },
      xaxis: { categories, axisBorder: { show: false }, axisTicks: { show: false }, tooltip: { enabled: false },
        labels: { rotate: 0, formatter: value => ticks.has(value) ? value : "" } },
      tooltip: { shared: true, intersect: false }
    });
    return { chart, style, ready: chart.render() };
  });
  if (!charts.length) return;
  new MutationObserver(() => {
    charts.forEach(({ chart, style, ready }) => ready.then(() => chart.updateOptions(style(), false, false)));
  }).observe(theme, { attributes: true, attributeFilter: ["data-bs-theme", "data-bs-theme-primary", "data-bs-theme-base"] });
});
