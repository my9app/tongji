"""
LiteStats - 轻量级网站统计系统
带登录认证 + 多站点管理
"""

from fastapi import FastAPI, Request, HTTPException, Depends, Response, Cookie
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel
from typing import Optional
from datetime import datetime, timedelta
import sqlite3
import hashlib
import secrets
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

# 配置
DB_PATH = os.getenv("DB_PATH", "/data/stats.db")
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("ADMIN_PASS", "admin123")
SECRET_KEY = os.getenv("SECRET_KEY", secrets.token_hex(32))

# Session 存储
sessions = {}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    cursor = conn.cursor()
    
    # 站点表 - 增加分组和备注
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS sites (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            domain TEXT NOT NULL UNIQUE,
            token TEXT NOT NULL UNIQUE,
            group_name TEXT DEFAULT '',
            notes TEXT DEFAULT '',
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
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    # 创建索引
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_site_time ON pageviews(site_id, timestamp)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_visitor ON pageviews(visitor_id)')
    
    conn.commit()
    conn.close()

init_db()

# ==================== 数据模型 ====================

class LoginData(BaseModel):
    username: str
    password: str

class SiteCreate(BaseModel):
    name: str
    domain: str
    group_name: Optional[str] = ""
    notes: Optional[str] = ""

class SiteUpdate(BaseModel):
    name: Optional[str] = None
    group_name: Optional[str] = None
    notes: Optional[str] = None

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

# ==================== 认证 ====================

def create_session():
    """创建 session"""
    session_id = secrets.token_hex(32)
    sessions[session_id] = {
        "created": datetime.now(),
        "expires": datetime.now() + timedelta(days=7)
    }
    return session_id

def verify_session(session_id: str) -> bool:
    """验证 session"""
    if not session_id or session_id not in sessions:
        return False
    session = sessions[session_id]
    if datetime.now() > session["expires"]:
        del sessions[session_id]
        return False
    return True

async def require_auth(request: Request):
    """需要登录的依赖"""
    session_id = request.cookies.get("session_id")
    if not verify_session(session_id):
        raise HTTPException(status_code=401, detail="请先登录")
    return True

# ==================== 工具函数 ====================

def generate_token():
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

# ==================== 登录相关 API ====================

@app.post("/api/login")
async def login(data: LoginData, response: Response):
    """登录"""
    if data.username == ADMIN_USER and data.password == ADMIN_PASS:
        session_id = create_session()
        response.set_cookie(
            key="session_id", 
            value=session_id, 
            httponly=True,
            max_age=7*24*60*60,  # 7天
            samesite="lax"
        )
        return {"success": True, "message": "登录成功"}
    raise HTTPException(status_code=401, detail="用户名或密码错误")

@app.post("/api/logout")
async def logout(response: Response, session_id: str = Cookie(None)):
    """登出"""
    if session_id and session_id in sessions:
        del sessions[session_id]
    response.delete_cookie("session_id")
    return {"success": True}

@app.get("/api/check-auth")
async def check_auth(session_id: str = Cookie(None)):
    """检查登录状态"""
    if verify_session(session_id):
        return {"authenticated": True, "username": ADMIN_USER}
    return {"authenticated": False}

# ==================== 站点管理 API ====================

@app.post("/api/sites")
async def create_site(site: SiteCreate, auth: bool = Depends(require_auth)):
    """创建站点"""
    conn = get_db()
    cursor = conn.cursor()
    token = generate_token()
    try:
        cursor.execute(
            "INSERT INTO sites (name, domain, token, group_name, notes) VALUES (?, ?, ?, ?, ?)",
            (site.name, site.domain, token, site.group_name, site.notes)
        )
        conn.commit()
        site_id = cursor.lastrowid
        return {"id": site_id, "name": site.name, "domain": site.domain, "token": token, 
                "group_name": site.group_name, "notes": site.notes}
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="域名已存在")
    finally:
        conn.close()

@app.get("/api/sites")
async def list_sites(auth: bool = Depends(require_auth)):
    """获取所有站点（按分组）"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("""
        SELECT id, name, domain, token, group_name, notes, created_at 
        FROM sites ORDER BY group_name, name
    """)
    sites = [dict(row) for row in cursor.fetchall()]
    
    # 获取每个站点的今日数据
    today = datetime.now().strftime("%Y-%m-%d")
    for site in sites:
        cursor.execute("""
            SELECT COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv 
            FROM pageviews WHERE site_id = ? AND DATE(timestamp) = ?
        """, (site["id"], today))
        stats = cursor.fetchone()
        site["today_pv"] = stats["pv"]
        site["today_uv"] = stats["uv"]
    
    conn.close()
    return sites

@app.put("/api/sites/{site_id}")
async def update_site(site_id: int, data: SiteUpdate, auth: bool = Depends(require_auth)):
    """更新站点信息"""
    conn = get_db()
    cursor = conn.cursor()
    
    updates = []
    values = []
    if data.name is not None:
        updates.append("name = ?")
        values.append(data.name)
    if data.group_name is not None:
        updates.append("group_name = ?")
        values.append(data.group_name)
    if data.notes is not None:
        updates.append("notes = ?")
        values.append(data.notes)
    
    if updates:
        values.append(site_id)
        cursor.execute(f"UPDATE sites SET {', '.join(updates)} WHERE id = ?", values)
        conn.commit()
    
    conn.close()
    return {"success": True}

@app.delete("/api/sites/{site_id}")
async def delete_site(site_id: int, auth: bool = Depends(require_auth)):
    """删除站点"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM pageviews WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM events WHERE site_id = ?", (site_id,))
    cursor.execute("DELETE FROM sites WHERE id = ?", (site_id,))
    conn.commit()
    conn.close()
    return {"success": True}

# ==================== 数据收集 API（无需登录）====================

@app.post("/api/collect/{token}")
async def collect(token: str, data: PageviewData, request: Request):
    """收集页面访问数据"""
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
    """收集自定义事件"""
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

# ==================== 统计数据 API ====================

@app.get("/api/stats/{site_id}")
async def stats(site_id: int, period: str = "7d", auth: bool = Depends(require_auth)):
    """获取统计数据"""
    conn = get_db()
    cursor = conn.cursor()
    
    now = datetime.now()
    periods = {"24h": 1, "7d": 7, "30d": 30, "90d": 90}
    days = periods.get(period, 7)
    start = (now - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
    
    # PV
    cursor.execute("SELECT COUNT(*) as pv FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, start))
    pv = cursor.fetchone()["pv"]
    
    # UV
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as uv FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, start))
    uv = cursor.fetchone()["uv"]
    
    # 每日趋势
    cursor.execute('''SELECT DATE(timestamp) as date, COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv
        FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY DATE(timestamp) ORDER BY date''', (site_id, start))
    daily = [dict(row) for row in cursor.fetchall()]
    
    # 热门页面
    cursor.execute('''SELECT path, COUNT(*) as views, COUNT(DISTINCT visitor_id) as visitors
        FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY path ORDER BY views DESC LIMIT 10''', (site_id, start))
    pages = [dict(row) for row in cursor.fetchall()]
    
    # 来源
    cursor.execute('''SELECT referrer_domain as source, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND referrer_domain != '' GROUP BY referrer_domain ORDER BY count DESC LIMIT 10''', (site_id, start))
    sources = [dict(row) for row in cursor.fetchall()]
    
    # 浏览器
    cursor.execute('''SELECT browser, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY browser ORDER BY count DESC''', (site_id, start))
    browsers = [dict(row) for row in cursor.fetchall()]
    
    # 操作系统
    cursor.execute('''SELECT os, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY os ORDER BY count DESC''', (site_id, start))
    os_list = [dict(row) for row in cursor.fetchall()]
    
    # 设备
    cursor.execute('''SELECT device, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? GROUP BY device ORDER BY count DESC''', (site_id, start))
    devices = [dict(row) for row in cursor.fetchall()]
    
    # 国家
    cursor.execute('''SELECT country, COUNT(*) as count FROM pageviews 
        WHERE site_id = ? AND timestamp >= ? AND country != '' GROUP BY country ORDER BY count DESC LIMIT 10''', (site_id, start))
    countries = [dict(row) for row in cursor.fetchall()]
    
    conn.close()
    return {"summary": {"pv": pv, "uv": uv}, "daily": daily, "pages": pages, "sources": sources,
        "browsers": browsers, "os": os_list, "devices": devices, "countries": countries}

@app.get("/api/realtime/{site_id}")
async def realtime(site_id: int, auth: bool = Depends(require_auth)):
    """获取实时数据"""
    conn = get_db()
    cursor = conn.cursor()
    t = (datetime.now() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as online FROM pageviews WHERE site_id = ? AND timestamp >= ?", (site_id, t))
    online = cursor.fetchone()["online"]
    cursor.execute("SELECT path, title, country, device, timestamp FROM pageviews WHERE site_id = ? ORDER BY timestamp DESC LIMIT 20", (site_id,))
    recent = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"online": online, "recent": recent}

@app.get("/api/overview")
async def overview(auth: bool = Depends(require_auth)):
    """获取所有站点汇总"""
    conn = get_db()
    cursor = conn.cursor()
    
    today = datetime.now().strftime("%Y-%m-%d")
    
    # 今日汇总
    cursor.execute("""
        SELECT COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv 
        FROM pageviews WHERE DATE(timestamp) = ?
    """, (today,))
    today_stats = dict(cursor.fetchone())
    
    # 站点数量
    cursor.execute("SELECT COUNT(*) as count FROM sites")
    site_count = cursor.fetchone()["count"]
    
    # 30分钟内在线
    t = (datetime.now() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as online FROM pageviews WHERE timestamp >= ?", (t,))
    online = cursor.fetchone()["online"]
    
    conn.close()
    return {
        "today_pv": today_stats["pv"],
        "today_uv": today_stats["uv"],
        "site_count": site_count,
        "online": online
    }

# ==================== 追踪脚本 ====================

@app.get("/tracker.js")
async def tracker():
    js = '''(function(){var E=window.LITESTATS_URL||'',T=window.LITESTATS_TOKEN||'';if(!E||!T)return;function s(p,d){var u=E+p+'/'+T;if(navigator.sendBeacon)navigator.sendBeacon(u,JSON.stringify(d));else{var x=new XMLHttpRequest();x.open('POST',u,true);x.setRequestHeader('Content-Type','application/json');x.send(JSON.stringify(d));}}function g(){return{url:location.href,title:document.title,referrer:document.referrer,screen_width:screen.width,screen_height:screen.height,language:navigator.language};}function t(){s('/api/collect',g());}window.litestats={track:function(n,d){s('/api/event',{name:n,data:d,url:location.href});}};if(document.readyState==='complete')t();else window.addEventListener('load',t);var l=location.href;new MutationObserver(function(){if(location.href!==l){l=location.href;t();}}).observe(document,{subtree:true,childList:true});})();'''
    return HTMLResponse(content=js, media_type="application/javascript")

# ==================== 页面 ====================

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    """登录页面"""
    return """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>登录 - LiteStats</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;display:flex;align-items:center;justify-content:center}
        .login-box{background:#fff;padding:40px;border-radius:16px;box-shadow:0 20px 60px rgba(0,0,0,0.3);width:100%;max-width:400px}
        .logo{text-align:center;margin-bottom:30px;font-size:32px}
        .title{text-align:center;font-size:24px;font-weight:600;margin-bottom:30px;color:#1e293b}
        .form-group{margin-bottom:20px}
        .form-group label{display:block;margin-bottom:8px;font-weight:500;color:#475569}
        .form-group input{width:100%;padding:14px;border:2px solid #e2e8f0;border-radius:10px;font-size:16px;transition:border-color 0.3s}
        .form-group input:focus{outline:none;border-color:#6366f1}
        .btn{width:100%;padding:14px;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;border:none;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer;transition:transform 0.2s,box-shadow 0.2s}
        .btn:hover{transform:translateY(-2px);box-shadow:0 10px 20px rgba(102,126,234,0.4)}
        .error{background:#fee2e2;color:#dc2626;padding:12px;border-radius:8px;margin-bottom:20px;display:none;text-align:center}
    </style>
</head>
<body>
    <div class="login-box">
        <div class="logo">📊</div>
        <div class="title">LiteStats 统计系统</div>
        <div class="error" id="error"></div>
        <div class="form-group">
            <label>用户名</label>
            <input type="text" id="username" placeholder="请输入用户名">
        </div>
        <div class="form-group">
            <label>密码</label>
            <input type="password" id="password" placeholder="请输入密码">
        </div>
        <button class="btn" onclick="login()">登 录</button>
    </div>
    <script>
        document.getElementById('password').addEventListener('keypress', function(e) {
            if (e.key === 'Enter') login();
        });
        async function login() {
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;
            const error = document.getElementById('error');
            
            if (!username || !password) {
                error.textContent = '请输入用户名和密码';
                error.style.display = 'block';
                return;
            }
            
            try {
                const resp = await fetch('/api/login', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({username, password})
                });
                
                if (resp.ok) {
                    window.location.href = '/';
                } else {
                    const data = await resp.json();
                    error.textContent = data.detail || '登录失败';
                    error.style.display = 'block';
                }
            } catch (e) {
                error.textContent = '网络错误';
                error.style.display = 'block';
            }
        }
    </script>
</body>
</html>
"""

@app.get("/", response_class=HTMLResponse)
async def dashboard(session_id: str = Cookie(None)):
    """仪表盘页面"""
    if not verify_session(session_id):
        return RedirectResponse(url="/login", status_code=302)
    
    with open("/app/frontend/index.html", "r", encoding="utf-8") as f:
        return f.read()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
