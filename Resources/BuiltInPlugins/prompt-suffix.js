// @name 回答风格约束
// @summary 在每条发往模型的消息末尾追加强调指令，指令内容可在「设置 → 插件 → 回答风格约束」中编辑
// @version 1.1.0
// @author DSH 内置
// @enabled false

// 未在设置里填写时使用的默认强调指令
var defaultSuffix = "[约束] 请用简洁的中文回答，先给结论再给要点。";

dsh.onMessage(function (text, role) {
  if (role !== "user") {
    return text;
  }
  var suffix = dsh.getSetting("styleSuffix");
  if (!suffix || suffix.trim() === "") {
    suffix = defaultSuffix;
  }
  return text + "\n\n" + suffix;
});