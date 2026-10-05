// @name 文本工具
// @summary 大小写转换与反转：/upper /lower /reverse
// @version 1.0.0
// @author DSH 内置

dsh.registerCommand("upper", "转为大写", function (text) {
  return (text || "").toUpperCase();
});

dsh.registerCommand("lower", "转为小写", function (text) {
  return (text || "").toLowerCase();
});

dsh.registerCommand("reverse", "反转文本", function (text) {
  return (text || "").split("").reverse().join("");
});
