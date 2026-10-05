// @name 回答风格约束
// @summary 在每条发往模型的消息末尾追加强调指令（默认关闭，可在插件页开启）
// @version 1.0.0
// @author DSH 内置
// @enabled false

dsh.onMessage(function (text, role) {
  if (role !== "user") {
    return text;
  }
  return text + "\n\n[约束] 请用简洁的中文回答，先给结论再给要点。";
});
