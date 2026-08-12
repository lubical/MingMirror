## 改了什么
<!-- 一句话说明本 PR 的目的 -->

## 改动类型
- [ ] 新增语料（corpus/）
- [ ] 新增/改进概念（concepts/）
- [ ] 改进方法/导读（methods/ guides/）
- [ ] CLI 代码改动（cli/）
- [ ] 文档改动
- [ ] 其他

## 提交前检查
<!-- 勾选你跑过的检查 -->
- [ ] `node tests/validate-corpus.mjs corpus concepts` 全过（改了 corpus/concepts 时必跑，需 Node.js）
- [ ] `cd cli && dart analyze` 零问题（改了 cli/ 时必跑）
- [ ] `cd cli && dart test` 全过（改了 cli/ 时必跑）
- [ ] 矩阵四载一致性（改了解药矩阵时核对：角色卡 §9 / 设计文档 §4 / paperkit / cli vector_search.dart）

## 安全检查（如涉及内容改动）
- [ ] 新增语料的"禁用场景"字段已填写且具体
- [ ] 未弱化任何安全条款
- [ ] 未在脆弱态场景示范"反求诸己/内自省"
- [ ] 毛泽东声部仅限哲学方法论（未涉政治立场/历史评价）

## 相关 Issue
<!-- 如有，写 closes #123 -->
