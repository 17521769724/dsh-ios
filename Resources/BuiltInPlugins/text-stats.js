// @name 文案统计
// @summary 统计字数、词数与行数：/count
// @version 1.0.0
// @author DSH 内置

dsh.registerCommand("count", "统计字数与词数", function (text) {
  var value = text || "";
  var chars = value.replace(/\s/g, "").length;
  var words = value.split(/\s+/).filter(function (item) { return item.length > 0; }).length;
  var lines = value.length === 0 ? 0 : value.split("\n").length;
  return "字数 " + chars + " · 词数 " + words + " · 行数 " + lines;
});
