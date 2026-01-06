#!/bin/bash

#=====================================================
# LiteStats - 轻量级网站统计系统
# 一键安装脚本
#=====================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认端口
PORT=${1:-8080}

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════╗"
echo "║       LiteStats 轻量级统计系统            ║"
echo "║       一键安装脚本 v1.0                   ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# 检查 Docker
check_docker() {
    echo -e "${YELLOW}[1/4] 检查 Docker...${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}未检测到 Docker，正在安装...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo -e "${RED}未检测到 Docker Compose，正在安装...${NC}"
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    echo -e "${GREEN}✓ Docker 已就绪${NC}"
}

# 创建项目目录
setup_project() {
    echo -e "${YELLOW}[2/4] 创建项目目录...${NC}"
    
    INSTALL_DIR="/opt/litestats"
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    
    echo -e "${GREEN}✓ 项目目录: $INSTALL_DIR${NC}"
}

# 下载项目文件
download_files() {
    echo -e "${YELLOW}[3/4] 创建项目文件...${NC}"
    
    # 创建目录结构
    mkdir -p backend frontend data

    # 创建 requirements.txt
    cat > backend/requirements.txt << 'EOF'
fastapi==0.109.0
uvicorn==0.27.0
httpx==0.26.0
user-agents==2.2.0
pydantic==2.5.3
EOF

    # 创建主程序
    cat > backend/main.py << 'MAINPY'
"""
LiteStats - 轻量级网站统计系统
"""

from fastapi import FastAPI, Request, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from typing import Optional
from datetime import datetime, timedelta
import sqlite3
import hashlib
import json
import os
import httpx
import user_agents

app = FastAPI(title="LiteStats")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_PATH = os.getenv("DB_PATH", "/data/stats.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    cursor = conn.cursor()
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS sites (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            domain TEXT NOT NULL UNIQUE,
            token TEXT NOT NULL UNIQUE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS pageviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            site_id INTEGER NOT NULL,
            visitor_id TEXT NOT NULL,
            url TEXT NOT NULL,
            path TEXT NOT NULL,
            title TEXT,
            referrer TEXT,
            referrer_domain TEXT,
            browser TEXT,
            os TEXT,
            device TEXT,
            country TEXT,
            city TEXT,
            screen_width INTEGER,
            screen_height INTEGER,
            language TEXT,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            site_id INTEGER NOT NULL,
            visitor_id TEXT NOT NULL,
            name TEXT NOT NULL,
            data TEXT,
            url TEXT,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_site_time ON pageviews(site_id, timestamp)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_visitor ON pageviews(visitor_id)')
    
    conn.commit()
    conn.close()

init_db()

class SiteCreate(BaseModel):
    name: str
    domain: str

class PageviewData(BaseModel):
    url: str
    title: Optional[str] = None
    referrer: Optional[str] = None
    screen_width: Optional[int] = None
    screen_height: Optional[int] = None
    language: Optional[str] = None

class EventData(BaseModel):
    name: str
    data: Optional[dict] = None
    url: Optional[str] = None

def generate_token():
    import secrets
    return secrets.token_urlsafe(16)

def hash_visitor(ip: str, ua: str, site_id: int) -> str:
    date_str = datetime.now().strftime("%Y-%m-%d")
    raw = f"{ip}{ua}{site_id}{date_str}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]

def parse_ua(ua_string: str) -> dict:
    ua = user_agents.parse(ua_string)
    return {
        "browser": ua.browser.family,
        "os": ua.os.family,
        "device": "Mobile" if ua.is_mobile else ("Tablet" if ua.is_tablet else "Desktop")
    }

def extract_domain(url: str) -> str:
    if not url: return ""
    try:
        from urllib.parse import urlparse
        return urlparse(url).netloc
    except: return ""

def extract_path(url: str) -> str:
    if not url: return "/"
    try:
        from urllib.parse import urlparse
        return urlparse(url).path or "/"
    except: return "/"

async def get_geo(ip: str) -> dict:
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(f"http://ip-api.com/json/{ip}?fields=country,city")
            if r.status_code == 200:
                d = r.json()
                return {"country": d.get("country", ""), "city": d.get("city", "")}
    except: pass
    return {"country": "", "city": ""}

def get_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded: return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("X-Real-IP")
    if real_ip: return real_ip
    return request.client.host

@app.post("/api/sites")
async def create_site(site: SiteCreate):
    conn = get_db()
    cursor = conn.cursor()
    token = generate_token()
    try:
        cursor.execute("INSERT INTO sites (name, domain, token) VALUES (?, ?, ?)", (site.name, site.domain, token))
        conn.commit()
        site_id = cursor.lastrowid
        return {"id": site_id, "name": site.name, "domain": site.domain, "token": token}
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="域名已存在")
    finally:
        conn.close()

@app.get("/api/sites")
async def list_sites():
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id, name, domain, token, created_at FROM sites")
    sites = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return sites

@app.delete("/api/sites/{site_id}")
async def delete_site(site_id: int):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM pageviews WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM events WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM sites WHERE id = ?", (site_id,))
    conn.commit()
    conn.close()
    return {"success": True}

@app.post("/api/collect/{token}")
async def collect(token: str, data: PageviewData, request: Request):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM sites WHERE token = ?", (token,))
    site = cursor.fetchone()
    if not site:
        conn.close()
        raise HTTPException(status_code=404, detail="站点不存在")
    
    site_id = site["id"]
    ip = get_ip(request)
    ua_string = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua_string, site_id)
    ua_info = parse_ua(ua_string)
    geo = await get_geo(ip)
    referrer_domain = extract_domain(data.referrer)
    path = extract_path(data.url)
    
    cursor.execute('''
        INSERT INTO pageviews (site_id, visitor_id, url, path, title, referrer, referrer_domain, 
         browser, os, device, country, city, screen_width, screen_height, language)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (site_id, visitor_id, data.url, path, data.title, data.referrer, referrer_domain,
        ua_info["browser"], ua_info["os"], ua_info["device"], geo["country"], geo["city"], 
        data.screen_width, data.screen_height, data.language))
    conn.commit()
    conn.close()
    return {"success": True}

@app.post("/api/event/{token}")
async def event(token: str, data: EventData, request: Request):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM sites WHERE token = ?", (token,))
    site = cursor.fetchone()
    if not site:
        conn.close()
        raise HTTPException(status_code=404, detail="站点不存在")
    
    site_id = site["id"]
    ip = get_ip(request)
    ua = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua, site_id)
    
    cursor.execute("INSERT INTO events (site_id, visitor_id, name, data, url) VALUES (?, ?, ?, ?, ?)",
        (site_id, visitor_id, data.name, json.dumps(data.data) if data.data else None, data.url))
    conn.commit()
    conn.close()
    return {"success": True}

@app.get("/api/stats/{site_id}")
async def stats(site_id: int, period: str = "7d"):
    conn = get_db()
    cursor = conn.cursor()
    
    now = datetime.now()
    periods = {"24h": 1, "7d": 7, "30d": 30, "90d": 90}
    days = periods.get(period, 7)
    start = (now - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
    
    cursor.execute("SELECT COUNT(*) as pv FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, start))
    pv = cursor.fetchone()["pv"]
    
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as uv FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, start))
    uv = cursor.fetchone()["uv"]
    
    cursor.execute('''SELECT DATE(timestamp) as date, COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv
        FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY DATE(timestamp) ORDER BY date''', (site_id, start))
    daily = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT path, COUNT(*) as views, COUNT(DISTINCT visitor_id) as visitors
        FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY path ORDER BY views DESC LIMIT 10''', (site_id, start))
    pages = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT referrer_domain as source, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND referrer_domain != '' GROUP BY referrer_domain ORDER BY count DESC LIMIT 10''', (site_id, start))
    sources = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT browser, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY browser ORDER BY count DESC''', (site_id, start))
    browsers = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT os, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY os ORDER BY count DESC''', (site_id, start))
    os_list = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT device, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY device ORDER BY count DESC''', (site_id, start))
    devices = [dict(row) for row in cursor.fetchall()]
    
    cursor.execute('''SELECT country, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND country != '' GROUP BY country ORDER BY count DESC LIMIT 10''', (site_id, start))
    countries = [dict(row) for row in cursor.fetchall()]
    
    conn.close()
    return {"summary": {"pv": pv, "uv": uv}, "daily": daily, "pages": pages, "sources": sources,
        "browsers": browsers, "os": os_list, "devices": devices, "countries": countries}

@app.get("/api/realtime/{site_id}")
async def realtime(site_id: int):
    conn = get_db()
    cursor = conn.cursor()
    t = (datetime.now() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as online FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, t))
    online = cursor.fetchone()["online"]
    cursor.execute("SELECT path, title, country, device, timestamp FROM pageviews WHERE site_id = ? ORDER BY timestamp DESC LIMIT 20", (site_id,))
    recent = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"online": online, "recent": recent}

@app.get("/tracker.js")
async def tracker():
    js = '''(function(){var E=window.LITESTATS_URL||'',T=window.LITESTATS_TOKEN||'';if(!E||!T)return;function s(p,d){var u=E+p+'/'+T;if(navigator.sendBeacon)navigator.sendBeacon(u,JSON.stringify(d));else{var x=new XMLHttpRequest();x.open('POST',u,true);x.setRequestHeader('Content-Type','application/json');x.send(JSON.stringify(d));}}function g(){return{url:location.href,title:document.title,referrer:document.referrer,screen_width:screen.width,screen_height:screen.height,language:navigator.language};}function t(){s('/api/collect',g());}window.litestats={track:function(n,d){s('/api/event',{name:n,data:d,url:location.href});}};if(document.readyState==='complete')t();else window.addEventListener('load',t);var l=location.href;new MutationObserver(function(){if(location.href!==l){l=location.href;t();}}).observe(document,{subtree:true,childList:true});})();'''
    return HTMLResponse(content=js, media_type="application/javascript")

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    with open("/app/frontend/index.html", "r", encoding="utf-8") as f:
        return f.read()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
MAINPY

    # 下载前端文件（简化版，完整版从GitHub获取）
    cat > frontend/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LiteStats - 轻量级统计</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}:root{--primary:#6366f1;--success:#10b981;--bg:#f8fafc;--card:#fff;--text:#1e293b;--text-light:#64748b;--border:#e2e8f0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text)}.header{background:linear-gradient(135deg,var(--primary),#4f46e5);color:#fff;padding:20px 30px;display:flex;justify-content:space-between;align-items:center}.logo{font-size:24px;font-weight:700}.container{max-width:1400px;margin:0 auto;padding:30px}.controls{display:flex;justify-content:space-between;align-items:center;margin-bottom:30px;flex-wrap:wrap;gap:15px}select,button{padding:10px 20px;border:1px solid var(--border);border-radius:8px;font-size:14px;cursor:pointer;background:#fff}button{background:var(--primary);color:#fff;border:none;font-weight:500}button:hover{opacity:.9}button.secondary{background:#fff;color:var(--text);border:1px solid var(--border)}.period-buttons{display:flex;gap:5px}.period-buttons button{padding:8px 16px;background:#fff;color:var(--text);border:1px solid var(--border)}.period-buttons button.active{background:var(--primary);color:#fff;border-color:var(--primary)}.card{background:var(--card);border-radius:12px;padding:25px;box-shadow:0 1px 3px rgba(0,0,0,.1);margin-bottom:20px}.card-title{font-size:14px;color:var(--text-light);margin-bottom:15px;font-weight:500}.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px;margin-bottom:30px}.stat-card{background:var(--card);border-radius:12px;padding:25px;box-shadow:0 1px 3px rgba(0,0,0,.1)}.stat-label{font-size:14px;color:var(--text-light);margin-bottom:8px}.stat-value{font-size:36px;font-weight:700}.stat-value.online{color:var(--success)}.charts-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:30px}.chart-full{grid-column:1/-1}.chart-container{position:relative;height:300px}.data-table{width:100%;border-collapse:collapse}.data-table th,.data-table td{padding:12px;text-align:left;border-bottom:1px solid var(--border)}.data-table th{font-weight:500;color:var(--text-light);font-size:12px;text-transform:uppercase}.progress-bar{width:100%;height:6px;background:var(--border);border-radius:3px;overflow:hidden}.progress-fill{height:100%;background:var(--primary);border-radius:3px}.modal{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.5);z-index:1000;align-items:center;justify-content:center}.modal.active{display:flex}.modal-content{background:#fff;padding:30px;border-radius:12px;max-width:500px;width:90%}.modal-title{font-size:20px;font-weight:600;margin-bottom:20px}.form-group{margin-bottom:20px}.form-group label{display:block;margin-bottom:8px;font-weight:500}.form-group input{width:100%;padding:12px;border:1px solid var(--border);border-radius:8px;font-size:14px}.modal-actions{display:flex;gap:10px;justify-content:flex-end}.code-block{background:#1e293b;color:#e2e8f0;padding:20px;border-radius:8px;font-family:monospace;font-size:13px;overflow-x:auto;margin-top:15px;white-space:pre-wrap;word-break:break-all}.realtime-list{max-height:400px;overflow-y:auto}.realtime-item{display:flex;align-items:center;padding:12px;border-bottom:1px solid var(--border);gap:15px}.device-icon{width:40px;height:40px;background:var(--bg);border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:20px}.realtime-info{flex:1}.realtime-path{font-weight:500;margin-bottom:2px}.realtime-meta{font-size:12px;color:var(--text-light)}@media(max-width:768px){.charts-grid{grid-template-columns:1fr}.container{padding:15px}.controls{flex-direction:column;align-items:stretch}}
    </style>
</head>
<body>
    <header class="header"><div class="logo">📊 LiteStats</div><button onclick="showAddSiteModal()">+ 添加站点</button></header>
    <div class="container">
        <div class="controls">
            <div style="display:flex;align-items:center;gap:15px"><select id="siteSelect" onchange="loadStats()"><option value="">选择站点...</option></select><button class="secondary" onclick="showTrackingCode()">获取代码</button></div>
            <div class="period-buttons"><button class="active" data-period="24h">24小时</button><button data-period="7d">7天</button><button data-period="30d">30天</button><button data-period="90d">90天</button></div>
        </div>
        <div class="stats-grid">
            <div class="stat-card"><div class="stat-label">👁️ 页面浏览量 (PV)</div><div class="stat-value" id="totalPV">0</div></div>
            <div class="stat-card"><div class="stat-label">👤 独立访客 (UV)</div><div class="stat-value" id="totalUV">0</div></div>
            <div class="stat-card"><div class="stat-label">🟢 当前在线</div><div class="stat-value online" id="onlineCount">0</div></div>
            <div class="stat-card"><div class="stat-label">📄 平均页面/访客</div><div class="stat-value" id="avgPages">0</div></div>
        </div>
        <div class="charts-grid">
            <div class="card chart-full"><div class="card-title">📈 访问趋势</div><div class="chart-container"><canvas id="trendChart"></canvas></div></div>
            <div class="card"><div class="card-title">🖥️ 设备分布</div><div class="chart-container"><canvas id="deviceChart"></canvas></div></div>
            <div class="card"><div class="card-title">🌐 浏览器分布</div><div class="chart-container"><canvas id="browserChart"></canvas></div></div>
        </div>
        <div class="charts-grid">
            <div class="card"><div class="card-title">🔥 热门页面</div><table class="data-table" id="pagesTable"><thead><tr><th>页面路径</th><th>访问量</th><th>占比</th></tr></thead><tbody></tbody></table></div>
            <div class="card"><div class="card-title">🔗 流量来源</div><table class="data-table" id="sourcesTable"><thead><tr><th>来源</th><th>访问量</th><th>占比</th></tr></thead><tbody></tbody></table></div>
        </div>
        <div class="charts-grid">
            <div class="card"><div class="card-title">🌍 国家分布</div><table class="data-table" id="countriesTable"><thead><tr><th>国家</th><th>访问量</th><th>占比</th></tr></thead><tbody></tbody></table></div>
            <div class="card"><div class="card-title">⚡ 实时访问</div><div class="realtime-list" id="realtimeList"><div style="text-align:center;padding:40px;color:#999">暂无数据</div></div></div>
        </div>
    </div>
    <div class="modal" id="addSiteModal"><div class="modal-content"><div class="modal-title">添加新站点</div><div class="form-group"><label>站点名称</label><input type="text" id="siteName" placeholder="我的网站"></div><div class="form-group"><label>域名</label><input type="text" id="siteDomain" placeholder="example.com"></div><div class="modal-actions"><button class="secondary" onclick="hideModal('addSiteModal')">取消</button><button onclick="addSite()">添加</button></div></div></div>
    <div class="modal" id="trackingCodeModal"><div class="modal-content"><div class="modal-title">追踪代码</div><p>将以下代码添加到网站的 &lt;head&gt; 标签中：</p><div class="code-block" id="trackingCode"></div><div class="modal-actions" style="margin-top:20px"><button onclick="copyCode()">复制代码</button><button class="secondary" onclick="hideModal('trackingCodeModal')">关闭</button></div></div></div>
    <script>
        let currentSite=null,currentPeriod='7d',sites=[],trendChart=null,deviceChart=null,browserChart=null;const API=location.origin;
        document.addEventListener('DOMContentLoaded',function(){loadSites();document.querySelectorAll('.period-buttons button').forEach(b=>b.addEventListener('click',function(){document.querySelectorAll('.period-buttons button').forEach(x=>x.classList.remove('active'));this.classList.add('active');currentPeriod=this.dataset.period;loadStats();}));setInterval(loadRealtime,30000);});
        async function loadSites(){const r=await fetch(`${API}/api/sites`);sites=await r.json();const s=document.getElementById('siteSelect');s.innerHTML='<option value="">选择站点...</option>';sites.forEach(x=>{const o=document.createElement('option');o.value=x.id;o.textContent=`${x.name} (${x.domain})`;o.dataset.token=x.token;s.appendChild(o);});if(sites.length>0){s.value=sites[0].id;currentSite=sites[0];loadStats();}}
        async function loadStats(){const siteId=document.getElementById('siteSelect').value;if(!siteId)return;currentSite=sites.find(s=>s.id==siteId);const r=await fetch(`${API}/api/stats/${siteId}?period=${currentPeriod}`);const d=await r.json();document.getElementById('totalPV').textContent=d.summary.pv.toLocaleString();document.getElementById('totalUV').textContent=d.summary.uv.toLocaleString();document.getElementById('avgPages').textContent=d.summary.uv>0?(d.summary.pv/d.summary.uv).toFixed(1):'0';updateTrendChart(d.daily);updateDeviceChart(d.devices);updateBrowserChart(d.browsers);updateTable('pagesTable',d.pages,'path','views',d.summary.pv);updateTable('sourcesTable',d.sources,'source','count',d.summary.pv);updateTable('countriesTable',d.countries,'country','count',d.summary.pv);loadRealtime();}
        async function loadRealtime(){if(!currentSite)return;const r=await fetch(`${API}/api/realtime/${currentSite.id}`);const d=await r.json();document.getElementById('onlineCount').textContent=d.online;const l=document.getElementById('realtimeList');if(d.recent.length===0){l.innerHTML='<div style="text-align:center;padding:40px;color:#999">暂无数据</div>';return;}l.innerHTML=d.recent.map(i=>`<div class="realtime-item"><div class="device-icon">${i.device==='Mobile'?'📱':'💻'}</div><div class="realtime-info"><div class="realtime-path">${i.path}</div><div class="realtime-meta">${i.country||'未知'} · ${i.timestamp}</div></div></div>`).join('');}
        function updateTrendChart(d){const ctx=document.getElementById('trendChart').getContext('2d');if(trendChart)trendChart.destroy();trendChart=new Chart(ctx,{type:'line',data:{labels:d.map(x=>x.date),datasets:[{label:'PV',data:d.map(x=>x.pv),borderColor:'#6366f1',backgroundColor:'rgba(99,102,241,0.1)',fill:true,tension:0.4},{label:'UV',data:d.map(x=>x.uv),borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.1)',fill:true,tension:0.4}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'top'}},scales:{y:{beginAtZero:true}}}});}
        function updateDeviceChart(d){const ctx=document.getElementById('deviceChart').getContext('2d');if(deviceChart)deviceChart.destroy();deviceChart=new Chart(ctx,{type:'doughnut',data:{labels:d.map(x=>x.device),datasets:[{data:d.map(x=>x.count),backgroundColor:['#6366f1','#10b981','#f59e0b','#ef4444','#8b5cf6']}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'bottom'}}}});}
        function updateBrowserChart(d){const ctx=document.getElementById('browserChart').getContext('2d');if(browserChart)browserChart.destroy();browserChart=new Chart(ctx,{type:'doughnut',data:{labels:d.map(x=>x.browser),datasets:[{data:d.map(x=>x.count),backgroundColor:['#6366f1','#10b981','#f59e0b','#ef4444','#8b5cf6','#ec4899']}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'bottom'}}}});}
        function updateTable(tid,d,lk,vk,t){const tb=document.querySelector(`#${tid} tbody`);if(d.length===0){tb.innerHTML='<tr><td colspan="3" style="text-align:center;color:#999">暂无数据</td></tr>';return;}tb.innerHTML=d.map(i=>{const p=t>0?(i[vk]/t*100).toFixed(1):0;return`<tr><td>${i[lk]||'直接访问'}</td><td>${i[vk]}</td><td><div class="progress-bar"><div class="progress-fill" style="width:${p}%"></div></div></td></tr>`;}).join('');}
        function showAddSiteModal(){document.getElementById('addSiteModal').classList.add('active');}
        function hideModal(id){document.getElementById(id).classList.remove('active');}
        async function addSite(){const n=document.getElementById('siteName').value.trim(),d=document.getElementById('siteDomain').value.trim();if(!n||!d){alert('请填写完整');return;}const r=await fetch(`${API}/api/sites`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,domain:d})});if(r.ok){hideModal('addSiteModal');document.getElementById('siteName').value='';document.getElementById('siteDomain').value='';loadSites();}else{const e=await r.json();alert(e.detail||'添加失败');}}
        function showTrackingCode(){if(!currentSite){alert('请先选择站点');return;}const c=`<script>\nwindow.LITESTATS_URL = '${API}';\nwindow.LITESTATS_TOKEN = '${currentSite.token}';\n<\/script>\n<script src="${API}/tracker.js"><\/script>`;document.getElementById('trackingCode').textContent=c;document.getElementById('trackingCodeModal').classList.add('active');}
        function copyCode(){navigator.clipboard.writeText(document.getElementById('trackingCode').textContent).then(()=>alert('已复制'));}
        document.querySelectorAll('.modal').forEach(m=>m.addEventListener('click',function(e){if(e.target===this)this.classList.remove('active');}));
    </script>
</body>
</html>
HTMLEOF

    # 创建 Dockerfile
    cat > Dockerfile << 'DOCKERFILE'
FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ /app/
COPY frontend/ /app/frontend/
RUN mkdir -p /data
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKERFILE

    # 创建 docker-compose.yml
    cat > docker-compose.yml << COMPOSEFILE
version: '3.8'
services:
  litestats:
    build: .
    container_name: litestats
    restart: always
    ports:
      - "${PORT}:8080"
    volumes:
      - ./data:/data
    environment:
      - DB_PATH=/data/stats.db
COMPOSEFILE

    echo -e "${GREEN}✓ 项目文件创建完成${NC}"
}

# 启动服务
start_service() {
    echo -e "${YELLOW}[4/4] 启动服务...${NC}"
    
    # 构建并启动
    docker compose up -d --build 2>/dev/null || docker-compose up -d --build
    
    sleep 3
    
    # 检查状态
    if docker ps | grep -q litestats; then
        echo -e "${GREEN}✓ LiteStats 启动成功!${NC}"
    else
        echo -e "${RED}启动失败，请检查日志：docker logs litestats${NC}"
        exit 1
    fi
}

# 显示完成信息
show_info() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         🎉 安装完成！                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  访问地址: ${BLUE}http://${LOCAL_IP}:${PORT}${NC}"
    echo -e "  本地地址: ${BLUE}http://localhost:${PORT}${NC}"
    echo ""
    echo -e "  管理命令:"
    echo -e "    查看日志: ${YELLOW}docker logs -f litestats${NC}"
    echo -e "    重启服务: ${YELLOW}cd /opt/litestats && docker compose restart${NC}"
    echo -e "    停止服务: ${YELLOW}docker stop litestats${NC}"
    echo -e "    卸载服务: ${YELLOW}docker rm -f litestats && rm -rf /opt/litestats${NC}"
    echo ""
    echo -e "  数据目录: /opt/litestats/data"
    echo ""
}

# 主流程
main() {
    check_docker
    setup_project
    download_files
    start_service
    show_info
}

main
