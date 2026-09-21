# Redis 编辑能力冒烟测试清单

需 `redis:7` docker 实例。

## 值编辑
- [ ] string: 双击 value 单元格 → 改值 → Apply → 验证 `GET key` 返回新值
- [ ] hash: 双击 value 单元格 → 改值 → Apply → 验证 `HGET key field` 返回新值
- [ ] hash: 改 field 名 → Apply → 验证旧 field 已删、新 field 存在
- [ ] hash: 同时改 field 名和 value → Apply → 验证只有一个新 field（C1 修复）
- [ ] list: 双击 value → 改值 → Apply → 验证 `LINDEX key idx` 返回新值
- [ ] zset: 改 score → Apply → 验证 `ZSCORE key member` 返回新 score
- [ ] zset: 改 member 名 → Apply → 验证旧 member 已删、新 member 存在
- [ ] zset: 同时改 member 名和 score → Apply → 验证只有一个新 member（C1 修复）

## 增删行
- [ ] hash: Insert 键 → 输入 field+value → Apply → 验证 `HLEN` +1
- [ ] hash: Delete 行 → Apply → 验证 `HLEN` -1
- [ ] list: Insert 行 → 输入 value → Apply → 验证 `LLEN` +1
- [ ] list: Delete 行（含重复值）→ 验证只删目标行（tombstone 方案）
- [ ] set: Insert 行 → 输入 member → Apply → 验证 `SCARD` +1
- [ ] set: Delete 行 → Apply → 验证 `SCARD` -1
- [ ] zset: Insert 行 → 输入 member+score → Apply → 验证 `ZCARD` +1
- [ ] zset: Delete 行 → Apply → 验证 `ZCARD` -1
- [ ] string: Insert 行 → 验证报错"不能插入行"
- [ ] string: Delete 行 → 验证报错"不能删除行"

## 键操作
- [ ] 删除键 → 右键 → 删除 → 确认 → 验证键不存在
- [ ] 重命名键 → 右键 → 重命名 → 输入新名 → 验证旧名不存在、新名存在
- [ ] 重命名键（目标已存在）→ 确认覆盖 → 验证
- [ ] 设置 TTL → 右键 → 设TTL → 输入秒数 → 验证 `TTL` 返回正数
- [ ] 设置 TTL = -1 → 验证触发 PERSIST → `TTL` 返回 -1
- [ ] 取消 TTL → 右键 → 取消TTL → 验证 `TTL` 返回 -1
- [ ] 查看 TTL → 右键 → 查看TTL → 弹窗显示秒数
- [ ] 查看 TTL（永不过期）→ 弹窗显示"无过期"
- [ ] 查看 TTL（键不存在）→ 弹窗显示"键不存在"
- [ ] 复制键名 → 右键 → 复制 → 粘贴验证

## 新建键
- [ ] 新建 string 键 → 输入名+类型+值 → 确定 → 验证键存在
- [ ] 新建 hash 键 → 多行 field value → 确定 → 验证 `HLEN` 正确
- [ ] 新建 list 键 → 多行元素 → 确定 → 验证 `LLEN` 正确
- [ ] 新建 set 键 → 多行 member → 确定 → 验证 `SCARD` 正确
- [ ] 新建 zset 键 → 多行 member score → 确定 → 验证 `ZCARD` 正确
- [ ] 新建键（空名）→ 验证报错"键名不能为空"

## UI
- [ ] 选中 Redis 键 → 信息栏显示 TYPE/SIZE/TTL/MEMORY
- [ ] 信息栏 TTL 显示：-1=永不过期，-2=键不存在
- [ ] 信息栏 MEMORY USAGE 不可用(Redis<4.0)时显示 N/A
- [ ] 选中 Redis 键 → tabEditor 隐藏
- [ ] 选中 Redis 键 → 网格键列不可编辑（双击无反应）
- [ ] 选中非 Redis 键 → 信息栏隐藏
- [ ] 大值编辑（>100KB string）→ 懒加载不覆盖用户编辑

## 错误处理
- [ ] 编辑时键被其他客户端删除 → 提示刷新
- [ ] 键类型已变（WRONGTYPE）→ 提示刷新
- [ ] EXPIRE 键不存在（返回 0）→ 提示"键不存在"
