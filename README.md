# 📊 LiteStats - 轻量级网站统计系统

整合了 Umami、Plausible、Ackee 等开源项目优点的轻量级、隐私友好的网站统计系统。

## ✨ 特性

- 🚀 **轻量级** - Docker 镜像小于 100MB，内存占用低
- 🔒 **隐私友好** - 无 Cookie，不存储用户 IP，符合 GDPR
- 📊 **实时统计** - PV、UV、在线用户实时更新
- 🌍 **地理位置** - 自动识别访客国家/城市
- 📱 **设备识别** - 浏览器、操作系统、设备类型
- 🔗 **来源追踪** - 记录流量来源
- 📈 **美观图表** - 趋势图、饼图、表格
- 🎯 **自定义事件** - 追踪按钮点击、表单提交等
- 🌐 **多站点** - 一个实例管理多个网站
- 🐳 **一键部署** - Docker Compose 快速启动

## 🚀 一键安装

```bash
# 先切换到 root
sudo -i

# 一键安装（默认端口 8080）
bash <(curl -Ls https://raw.githubusercontent.com/my9app/tongji/main/install.sh)

# 自定义端口（如 9000）
bash <(curl -Ls https://raw.githubusercontent.com/my9app/tongji/main/install.sh) 9000
```

## 📖 使用指南

### 1. 添加站点

打开仪表盘，点击「添加站点」，填写：
- 站点名称（如：我的博客）
- 域名（如：blog.example.com）

### 2. 获取追踪代码

选择站点后点击「获取代码」，将代码添加到网站的 `<head>` 中：

```html
<script>
window.LITESTATS_URL = 'http://your-server:8080';
window.LITESTATS_TOKEN = 'your-token-here';
</script>
<script src="http://your-server:8080/tracker.js"></script>
```

### 3. 追踪自定义事件

```javascript
// 追踪按钮点击
litestats.track('button_click', { button: 'signup' });

// 追踪表单提交
litestats.track('form_submit', { form: 'contact' });

// 追踪购买
litestats.track('purchase', { amount: 99.99, product: 'pro_plan' });
```

## 📡 API 接口

### 站点管理

```bash
# 获取所有站点
GET /api/sites

# 创建站点
POST /api/sites
{"name": "我的网站", "domain": "example.com"}

# 删除站点
DELETE /api/sites/{site_id}
```

### 统计数据

```bash
# 获取统计数据（period: 24h, 7d, 30d, 90d）
GET /api/stats/{site_id}?period=7d

# 获取实时数据
GET /api/realtime/{site_id}
```

## ⚙️ 配置

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DB_PATH` | 数据库路径 | `/data/stats.db` |
| `PORT` | 服务端口 | `8080` |

## 🔧 管理命令

```bash
# 查看日志
docker logs -f litestats

# 重启服务
docker restart litestats

# 停止服务
docker stop litestats

# 备份数据
cp /opt/litestats/data/stats.db ~/backup/

# 卸载
docker rm -f litestats && rm -rf /opt/litestats
```

## 📊 与其他项目对比

| 特性 | LiteStats | Umami | Plausible | Matomo |
|------|-----------|-------|-----------|--------|
| 开源 | ✅ | ✅ | ✅ | ✅ |
| 隐私友好 | ✅ | ✅ | ✅ | ⚠️ |
| 无 Cookie | ✅ | ✅ | ✅ | ❌ |
| 实时统计 | ✅ | ✅ | ❌ | ✅ |
| 自定义事件 | ✅ | ✅ | ✅ | ✅ |
| 资源占用 | 极低 | 低 | 低 | 高 |
| 安装难度 | 简单 | 简单 | 中等 | 复杂 |

## 📝 许可证

MIT License
