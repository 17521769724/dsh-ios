// @name 时间戳助手
// @summary 通过 /time 命令向输入框插入当前时间
// @version 1.0.0
// @author DSH 内置

dsh.registerCommand("time", "插入当前时间", function () {
  var d = new Date();
  function pad(n) { return n < 10 ? "0" + n : "" + n; }
  return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
});

dsh.registerCommand("date", "插入当前日期", function () {
  var d = new Date();
  function pad(n) { return n < 10 ? "0" + n : "" + n; }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
});
