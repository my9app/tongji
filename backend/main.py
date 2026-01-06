"""
LiteStats - 轻量级网站统计系统
整合 Umami、Plausible、Ackee 等开源项目优点
"""

from fastapi import FastAPI, Request, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime, timedelta
from collections import defaultdict
import sqlite3
import hashlib
import json
import os
import httpx
import user_agents

app = FastAPI(title="LiteStats", description="轻量级网站统计系统")

# CORS 配置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 数据库路径
DB_PATH = os.getenv("DB_PATH", "/data/stats.db")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """初始化数据库表"""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    cursor = conn.cursor()
    
    # 站点表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS sites (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            domain TEXT NOT NULL UNIQUE,
            token TEXT NOT NULL UNIQUE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    # 访问记录表
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
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (site_id) REFERENCES sites(id)
        )
    ''')
    
    # 事件表
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            site_id INTEGER NOT NULL,
            visitor_id TEXT NOT NULL,
            name TEXT NOT NULL,
            data TEXT,
            url TEXT,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (site_id) REFERENCES sites(id)
        )
    ''')
    
    # 创建索引
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pageviews_site_time ON pageviews(site_id, timestamp)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pageviews_visitor ON pageviews(visitor_id)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_events_site_time ON events(site_id, timestamp)')
    
    conn.commit()
    conn.close()

# 初始化数据库
init_db()

# ==================== 数据模型 ====================

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

# ==================== 工具函数 ====================

def generate_token():
    """生成站点 token"""
    import secrets
    return secrets.token_urlsafe(16)

def hash_visitor(ip: str, user_agent: str, site_id: int) -> str:
    """生成访客唯一标识（隐私友好，不存储IP）"""
    date_str = datetime.now().strftime("%Y-%m-%d")
    raw = f"{ip}{user_agent}{site_id}{date_str}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]

def parse_user_agent(ua_string: str) -> dict:
    """解析 User-Agent"""
    ua = user_agents.parse(ua_string)
    return {
        "browser": ua.browser.family,
        "os": ua.os.family,
        "device": "Mobile" if ua.is_mobile else ("Tablet" if ua.is_tablet else "Desktop")
    }

def extract_domain(url: str) -> str:
    """提取域名"""
    if not url:
        return ""
    try:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        return parsed.netloc
    except:
        return ""

def extract_path(url: str) -> str:
    """提取路径"""
    if not url:
        return "/"
    try:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        return parsed.path or "/"
    except:
        return "/"

async def get_geo_info(ip: str) -> dict:
    """获取地理位置信息"""
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            resp = await client.get(f"http://ip-api.com/json/{ip}?fields=country,city")
            if resp.status_code == 200:
                data = resp.json()
                return {"country": data.get("country", ""), "city": data.get("city", "")}
    except:
        pass
    return {"country": "", "city": ""}

def get_client_ip(request: Request) -> str:
    """获取客户端真实IP"""
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip
    return request.client.host

# ==================== API 路由 ====================

# ----- 站点管理 -----

@app.post("/api/sites")
async def create_site(site: SiteCreate):
    """创建站点"""
    conn = get_db()
    cursor = conn.cursor()
    token = generate_token()
    try:
        cursor.execute(
            "INSERT INTO sites (name, domain, token) VALUES (?, ?, ?)",
            (site.name, site.domain, token)
        )
        conn.commit()
        site_id = cursor.lastrowid
        return {"id": site_id, "name": site.name, "domain": site.domain, "token": token}
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="域名已存在")
    finally:
        conn.close()

@app.get("/api/sites")
async def list_sites():
    """获取所有站点"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id, name, domain, token, created_at FROM sites")
    sites = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return sites

@app.delete("/api/sites/{site_id}")
async def delete_site(site_id: int):
    """删除站点"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM pageviews WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM events WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM sites WHERE id = ?", (site_id,))
    conn.commit()
    conn.close()
    return {"success": True}

# ----- 数据收集 -----

@app.post("/api/collect/{token}")
async def collect_pageview(token: str, data: PageviewData, request: Request):
    """收集页面访问数据"""
    conn = get_db()
    cursor = conn.cursor()
    
    # 验证站点
    cursor.execute("SELECT id FROM sites WHERE token = ?", (token,))
    site = cursor.fetchone()
    if not site:
        conn.close()
        raise HTTPException(status_code=404, detail="站点不存在")
    
    site_id = site["id"]
    
    # 获取访客信息
    ip = get_client_ip(request)
    ua_string = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua_string, site_id)
    
    # 解析 User-Agent
    ua_info = parse_user_agent(ua_string)
    
    # 获取地理位置
    geo = await get_geo_info(ip)
    
    # 解析来源
    referrer_domain = extract_domain(data.referrer) if data.referrer else ""
    path = extract_path(data.url)
    
    # 插入记录
    cursor.execute('''
        INSERT INTO pageviews 
        (site_id, visitor_id, url, path, title, referrer, referrer_domain, 
         browser, os, device, country, city, screen_width, screen_height, language)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        site_id, visitor_id, data.url, path, data.title, data.referrer, referrer_domain,
        ua_info["browser"], ua_info["os"], ua_info["device"],
        geo["country"], geo["city"], data.screen_width, data.screen_height, data.language
    ))
    
    conn.commit()
    conn.close()
    
    return {"success": True}

@app.post("/api/event/{token}")
async def collect_event(token: str, data: EventData, request: Request):
    """收集自定义事件"""
    conn = get_db()
    cursor = conn.cursor()
    
    cursor.execute("SELECT id FROM sites WHERE token = ?", (token,))
    site = cursor.fetchone()
    if not site:
        conn.close()
        raise HTTPException(status_code=404, detail="站点不存在")
    
    site_id = site["id"]
    ip = get_client_ip(request)
    ua_string = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua_string, site_id)
    
    cursor.execute('''
        INSERT INTO events (site_id, visitor_id, name, data, url)
        VALUES (?, ?, ?, ?, ?)
    ''', (site_id, visitor_id, data.name, json.dumps(data.data) if data.data else None, data.url))
    
    conn.commit()
    conn.close()
    
    return {"success": True}

# ----- 统计数据 -----

@app.get("/api/stats/{site_id}")
async def get_stats(site_id: int, period: str = "7d"):
    """获取统计数据"""
    conn = get_db()
    cursor = conn.cursor()
    
    # 解析时间范围
    now = datetime.now()
    if period == "24h":
        start_time = now - timedelta(hours=24)
    elif period == "7d":
        start_time = now - timedelta(days=7)
    elif period == "30d":
        start_time = now - timedelta(days=30)
    elif period == "90d":
        start_time = now - timedelta(days=90)
    else:
        start_time = now - timedelta(days=7)
    
    start_str = start_time.strftime("%Y-%m-%d %H:%M:%S")
    
    # 总 PV
    cursor.execute('''
        SELECT COUNT(*) as pv FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
    ''', (site_id, start_str))
    pv = cursor.fetchone()["pv"]
    
    # 总 UV
    cursor.execute('''
        SELECT COUNT(DISTINCT visitor_id) as uv FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
    ''', (site_id, start_str))
    uv = cursor.fetchone()["uv"]
    
    # 每日访问趋势
    cursor.execute('''
        SELECT DATE(timestamp) as date, 
               COUNT(*) as pv, 
               COUNT(DISTINCT visitor_id) as uv
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
        GROUP BY DATE(timestamp)
        ORDER BY date
    ''', (site_id, start_str))
    daily = [dict(row) for row in cursor.fetchall()]
    
    # 热门页面
    cursor.execute('''
        SELECT path, COUNT(*) as views, COUNT(DISTINCT visitor_id) as visitors
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
        GROUP BY path
        ORDER BY views DESC
        LIMIT 10
    ''', (site_id, start_str))
    pages = [dict(row) for row in cursor.fetchall()]
    
    # 来源统计
    cursor.execute('''
        SELECT referrer_domain as source, COUNT(*) as count
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND referrer_domain != ''
        GROUP BY referrer_domain
        ORDER BY count DESC
        LIMIT 10
    ''', (site_id, start_str))
    sources = [dict(row) for row in cursor.fetchall()]
    
    # 浏览器统计
    cursor.execute('''
        SELECT browser, COUNT(*) as count
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
        GROUP BY browser
        ORDER BY count DESC
    ''', (site_id, start_str))
    browsers = [dict(row) for row in cursor.fetchall()]
    
    # 操作系统统计
    cursor.execute('''
        SELECT os, COUNT(*) as count
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
        GROUP BY os
        ORDER BY count DESC
    ''', (site_id, start_str))
    operating_systems = [dict(row) for row in cursor.fetchall()]
    
    # 设备统计
    cursor.execute('''
        SELECT device, COUNT(*) as count
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
        GROUP BY device
        ORDER BY count DESC
    ''', (site_id, start_str))
    devices = [dict(row) for row in cursor.fetchall()]
    
    # 国家统计
    cursor.execute('''
        SELECT country, COUNT(*) as count
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND country != ''
        GROUP BY country
        ORDER BY count DESC
        LIMIT 10
    ''', (site_id, start_str))
    countries = [dict(row) for row in cursor.fetchall()]
    
    conn.close()
    
    return {
        "summary": {"pv": pv, "uv": uv},
        "daily": daily,
        "pages": pages,
        "sources": sources,
        "browsers": browsers,
        "os": operating_systems,
        "devices": devices,
        "countries": countries
    }

@app.get("/api/realtime/{site_id}")
async def get_realtime(site_id: int):
    """获取实时数据（最近30分钟）"""
    conn = get_db()
    cursor = conn.cursor()
    
    thirty_min_ago = (datetime.now() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    
    # 在线访客数
    cursor.execute('''
        SELECT COUNT(DISTINCT visitor_id) as online
        FROM pageviews 
        WHERE site_id = ? AND timestamp >= ?
    ''', (site_id, thirty_min_ago))
    online = cursor.fetchone()["online"]
    
    # 最近访问
    cursor.execute('''
        SELECT path, title, country, device, timestamp
        FROM pageviews 
        WHERE site_id = ?
        ORDER BY timestamp DESC
        LIMIT 20
    ''', (site_id,))
    recent = [dict(row) for row in cursor.fetchall()]
    
    conn.close()
    
    return {"online": online, "recent": recent}

# ----- 追踪脚本 -----

@app.get("/tracker.js")
async def get_tracker():
    """返回追踪脚本"""
    js_code = '''
(function() {
    'use strict';
    
    var ENDPOINT = window.LITESTATS_URL || '';
    var TOKEN = window.LITESTATS_TOKEN || '';
    
    if (!ENDPOINT || !TOKEN) {
        console.warn('LiteStats: Missing configuration');
        return;
    }
    
    function send(path, data) {
        var url = ENDPOINT + path + '/' + TOKEN;
        if (navigator.sendBeacon) {
            navigator.sendBeacon(url, JSON.stringify(data));
        } else {
            var xhr = new XMLHttpRequest();
            xhr.open('POST', url, true);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.send(JSON.stringify(data));
        }
    }
    
    function getPageData() {
        return {
            url: window.location.href,
            title: document.title,
            referrer: document.referrer,
            screen_width: window.screen.width,
            screen_height: window.screen.height,
            language: navigator.language
        };
    }
    
    // 页面访问
    function trackPageview() {
        send('/api/collect', getPageData());
    }
    
    // 自定义事件
    window.litestats = {
        track: function(name, data) {
            send('/api/event', {
                name: name,
                data: data,
                url: window.location.href
            });
        }
    };
    
    // 初始化
    if (document.readyState === 'complete') {
        trackPageview();
    } else {
        window.addEventListener('load', trackPageview);
    }
    
    // SPA 支持 - 监听 URL 变化
    var lastUrl = location.href;
    new MutationObserver(function() {
        if (location.href !== lastUrl) {
            lastUrl = location.href;
            trackPageview();
        }
    }).observe(document, {subtree: true, childList: true});
    
})();
'''
    return HTMLResponse(content=js_code, media_type="application/javascript")

# ----- 仪表盘 -----

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    """返回仪表盘页面"""
    with open("/app/frontend/index.html", "r", encoding="utf-8") as f:
        return f.read()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
