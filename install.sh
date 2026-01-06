#!/bin/bash

#=====================================================
# LiteStats - 轻量级网站统计系统
# 一键安装脚本 v2.0 (带登录认证)
#=====================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认配置
PORT=${1:-8080}
ADMIN_USER=${2:-admin}
ADMIN_PASS=${3:-admin123}

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════╗"
echo "║       LiteStats 轻量级统计系统            ║"
echo "║       一键安装脚本 v2.0                   ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# 检查是否提供了自定义密码
if [ "$ADMIN_PASS" == "admin123" ]; then
    echo -e "${YELLOW}提示：使用默认密码 admin123，建议修改！${NC}"
    echo -e "${YELLOW}用法：bash install.sh [端口] [用户名] [密码]${NC}"
    echo -e "${YELLOW}示例：bash install.sh 8080 admin MySecurePass123${NC}"
    echo ""
fi

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

setup_project() {
    echo -e "${YELLOW}[2/4] 创建项目目录...${NC}"
    
    INSTALL_DIR="/opt/litestats"
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    
    echo -e "${GREEN}✓ 项目目录: $INSTALL_DIR${NC}"
}

download_files() {
    echo -e "${YELLOW}[3/4] 创建项目文件...${NC}"
    
    mkdir -p backend frontend data

    # requirements.txt
    cat > backend/requirements.txt << 'EOF'
fastapi==0.109.0
uvicorn==0.27.0
httpx==0.26.0
user-agents==2.2.0
pydantic==2.5.3
EOF

    # main.py (后端代码)
    cat > backend/main.py << 'MAINPY'
"""
LiteStats - 轻量级网站统计系统 (带登录认证)
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

DB_PATH = os.getenv("DB_PATH", "/data/stats.db")
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("ADMIN_PASS", "admin123")
SECRET_KEY = os.getenv("SECRET_KEY", secrets.token_hex(32))

sessions = {}

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('''CREATE TABLE IF NOT EXISTS sites (id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,domain TEXT NOT NULL UNIQUE,token TEXT NOT NULL UNIQUE,group_name TEXT DEFAULT '',notes TEXT DEFAULT '',created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    cursor.execute('''CREATE TABLE IF NOT EXISTS pageviews (id INTEGER PRIMARY KEY AUTOINCREMENT,site_id INTEGER NOT NULL,visitor_id TEXT NOT NULL,url TEXT NOT NULL,path TEXT NOT NULL,title TEXT,referrer TEXT,referrer_domain TEXT,browser TEXT,os TEXT,device TEXT,country TEXT,city TEXT,screen_width INTEGER,screen_height INTEGER,language TEXT,timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    cursor.execute('''CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT,site_id INTEGER NOT NULL,visitor_id TEXT NOT NULL,name TEXT NOT NULL,data TEXT,url TEXT,timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_site_time ON pageviews(site_id, timestamp)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_pv_visitor ON pageviews(visitor_id)')
    conn.commit()
    conn.close()

init_db()

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

def create_session():
    session_id = secrets.token_hex(32)
    sessions[session_id] = {"created": datetime.now(), "expires": datetime.now() + timedelta(days=7)}
    return session_id

def verify_session(session_id: str) -> bool:
    if not session_id or session_id not in sessions: return False
    session = sessions[session_id]
    if datetime.now() > session["expires"]:
        del sessions[session_id]
        return False
    return True

async def require_auth(request: Request):
    session_id = request.cookies.get("session_id")
    if not verify_session(session_id): raise HTTPException(status_code=401, detail="请先登录")
    return True

def generate_token(): return secrets.token_urlsafe(16)

def hash_visitor(ip: str, ua: str, site_id: int) -> str:
    date_str = datetime.now().strftime("%Y-%m-%d")
    return hashlib.sha256(f"{ip}{ua}{site_id}{date_str}".encode()).hexdigest()[:16]

def parse_ua(ua_string: str) -> dict:
    ua = user_agents.parse(ua_string)
    return {"browser": ua.browser.family, "os": ua.os.family, "device": "Mobile" if ua.is_mobile else ("Tablet" if ua.is_tablet else "Desktop")}

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

@app.post("/api/login")
async def login(data: LoginData, response: Response):
    if data.username == ADMIN_USER and data.password == ADMIN_PASS:
        session_id = create_session()
        response.set_cookie(key="session_id", value=session_id, httponly=True, max_age=7*24*60*60, samesite="lax")
        return {"success": True, "message": "登录成功"}
    raise HTTPException(status_code=401, detail="用户名或密码错误")

@app.post("/api/logout")
async def logout(response: Response, session_id: str = Cookie(None)):
    if session_id and session_id in sessions: del sessions[session_id]
    response.delete_cookie("session_id")
    return {"success": True}

@app.get("/api/check-auth")
async def check_auth(session_id: str = Cookie(None)):
    if verify_session(session_id): return {"authenticated": True, "username": ADMIN_USER}
    return {"authenticated": False}

@app.post("/api/sites")
async def create_site(site: SiteCreate, auth: bool = Depends(require_auth)):
    conn = get_db()
    cursor = conn.cursor()
    token = generate_token()
    try:
        cursor.execute("INSERT INTO sites (name, domain, token, group_name, notes) VALUES (?, ?, ?, ?, ?)", (site.name, site.domain, token, site.group_name, site.notes))
        conn.commit()
        site_id = cursor.lastrowid
        return {"id": site_id, "name": site.name, "domain": site.domain, "token": token, "group_name": site.group_name, "notes": site.notes}
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=400, detail="域名已存在")
    finally:
        conn.close()

@app.get("/api/sites")
async def list_sites(auth: bool = Depends(require_auth)):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id, name, domain, token, group_name, notes, created_at FROM sites ORDER BY group_name, name")
    sites = [dict(row) for row in cursor.fetchall()]
    today = datetime.now().strftime("%Y-%m-%d")
    for site in sites:
        cursor.execute("SELECT COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv FROM pageviews WHERE site_id = ? AND DATE(timestamp) = ?", (site["id"], today))
        stats = cursor.fetchone()
        site["today_pv"] = stats["pv"]
        site["today_uv"] = stats["uv"]
    conn.close()
    return sites

@app.put("/api/sites/{site_id}")
async def update_site(site_id: int, data: SiteUpdate, auth: bool = Depends(require_auth)):
    conn = get_db()
    cursor = conn.cursor()
    updates, values = [], []
    if data.name is not None: updates.append("name = ?"); values.append(data.name)
    if data.group_name is not None: updates.append("group_name = ?"); values.append(data.group_name)
    if data.notes is not None: updates.append("notes = ?"); values.append(data.notes)
    if updates:
        values.append(site_id)
        cursor.execute(f"UPDATE sites SET {', '.join(updates)} WHERE id = ?", values)
        conn.commit()
    conn.close()
    return {"success": True}

@app.delete("/api/sites/{site_id}")
async def delete_site(site_id: int, auth: bool = Depends(require_auth)):
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
    if not site: conn.close(); raise HTTPException(status_code=404, detail="站点不存在")
    site_id = site["id"]
    ip = get_ip(request)
    ua_string = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua_string, site_id)
    ua_info = parse_ua(ua_string)
    geo = await get_geo(ip)
    referrer_domain = extract_domain(data.referrer)
    path = extract_path(data.url)
    cursor.execute('INSERT INTO pageviews (site_id, visitor_id, url, path, title, referrer, referrer_domain, browser, os, device, country, city, screen_width, screen_height, language) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', (site_id, visitor_id, data.url, path, data.title, data.referrer, referrer_domain, ua_info["browser"], ua_info["os"], ua_info["device"], geo["country"], geo["city"], data.screen_width, data.screen_height, data.language))
    conn.commit()
    conn.close()
    return {"success": True}

@app.post("/api/event/{token}")
async def event(token: str, data: EventData, request: Request):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM sites WHERE token = ?", (token,))
    site = cursor.fetchone()
    if not site: conn.close(); raise HTTPException(status_code=404, detail="站点不存在")
    site_id = site["id"]
    ip = get_ip(request)
    ua = request.headers.get("User-Agent", "")
    visitor_id = hash_visitor(ip, ua, site_id)
    cursor.execute("INSERT INTO events (site_id, visitor_id, name, data, url) VALUES (?, ?, ?, ?, ?)", (site_id, visitor_id, data.name, json.dumps(data.data) if data.data else None, data.url))
    conn.commit()
    conn.close()
    return {"success": True}

@app.get("/api/stats/{site_id}")
async def stats(site_id: int, period: str = "7d", auth: bool = Depends(require_auth)):
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
    cursor.execute('SELECT DATE(timestamp) as date, COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY DATE(timestamp) ORDER BY date', (site_id, start))
    daily = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT path, COUNT(*) as views, COUNT(DISTINCT visitor_id) as visitors FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY path ORDER BY views DESC LIMIT 10', (site_id, start))
    pages = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT referrer_domain as source, COUNT(*) as count FROM pageviews WHERE site_id = ? AND timestamp >= ? AND referrer_domain != \'\' GROUP BY referrer_domain ORDER BY count DESC LIMIT 10', (site_id, start))
    sources = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT browser, COUNT(*) as count FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY browser ORDER BY count DESC', (site_id, start))
    browsers = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT os, COUNT(*) as count FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY os ORDER BY count DESC', (site_id, start))
    os_list = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT device, COUNT(*) as count FROM pageviews WHERE site_id = ? AND timestamp >= ? GROUP BY device ORDER BY count DESC', (site_id, start))
    devices = [dict(row) for row in cursor.fetchall()]
    cursor.execute('SELECT country, COUNT(*) as count FROM pageviews WHERE site_id = ? AND timestamp >= ? AND country != \'\' GROUP BY country ORDER BY count DESC LIMIT 10', (site_id, start))
    countries = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return {"summary": {"pv": pv, "uv": uv}, "daily": daily, "pages": pages, "sources": sources, "browsers": browsers, "os": os_list, "devices": devices, "countries": countries}

@app.get("/api/realtime/{site_id}")
async def realtime(site_id: int, auth: bool = Depends(require_auth)):
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
    conn = get_db()
    cursor = conn.cursor()
    today = datetime.now().strftime("%Y-%m-%d")
    cursor.execute("SELECT COUNT(*) as pv, COUNT(DISTINCT visitor_id) as uv FROM pageviews WHERE DATE(timestamp) = ?", (today,))
    today_stats = dict(cursor.fetchone())
    cursor.execute("SELECT COUNT(*) as count FROM sites")
    site_count = cursor.fetchone()["count"]
    t = (datetime.now() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    cursor.execute("SELECT COUNT(DISTINCT visitor_id) as online FROM pageviews WHERE timestamp >= ?", (t,))
    online = cursor.fetchone()["online"]
    conn.close()
    return {"today_pv": today_stats["pv"], "today_uv": today_stats["uv"], "site_count": site_count, "online": online}

@app.get("/tracker.js")
async def tracker():
    js = '(function(){var E=window.LITESTATS_URL||\'\',T=window.LITESTATS_TOKEN||\'\';if(!E||!T)return;function s(p,d){var u=E+p+\'/\'+T;if(navigator.sendBeacon)navigator.sendBeacon(u,JSON.stringify(d));else{var x=new XMLHttpRequest();x.open(\'POST\',u,true);x.setRequestHeader(\'Content-Type\',\'application/json\');x.send(JSON.stringify(d));}}function g(){return{url:location.href,title:document.title,referrer:document.referrer,screen_width:screen.width,screen_height:screen.height,language:navigator.language};}function t(){s(\'/api/collect\',g());}window.litestats={track:function(n,d){s(\'/api/event\',{name:n,data:d,url:location.href});}};if(document.readyState===\'complete\')t();else window.addEventListener(\'load\',t);var l=location.href;new MutationObserver(function(){if(location.href!==l){l=location.href;t();}}).observe(document,{subtree:true,childList:true});})();'
    return HTMLResponse(content=js, media_type="application/javascript")

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    return '''<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>登录 - LiteStats</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;display:flex;align-items:center;justify-content:center}.login-box{background:#fff;padding:40px;border-radius:16px;box-shadow:0 20px 60px rgba(0,0,0,0.3);width:100%;max-width:400px}.logo{text-align:center;margin-bottom:30px;font-size:32px}.title{text-align:center;font-size:24px;font-weight:600;margin-bottom:30px;color:#1e293b}.form-group{margin-bottom:20px}.form-group label{display:block;margin-bottom:8px;font-weight:500;color:#475569}.form-group input{width:100%;padding:14px;border:2px solid #e2e8f0;border-radius:10px;font-size:16px;transition:border-color 0.3s}.form-group input:focus{outline:none;border-color:#6366f1}.btn{width:100%;padding:14px;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:#fff;border:none;border-radius:10px;font-size:16px;font-weight:600;cursor:pointer;transition:transform 0.2s,box-shadow 0.2s}.btn:hover{transform:translateY(-2px);box-shadow:0 10px 20px rgba(102,126,234,0.4)}.error{background:#fee2e2;color:#dc2626;padding:12px;border-radius:8px;margin-bottom:20px;display:none;text-align:center}</style></head><body><div class="login-box"><div class="logo">📊</div><div class="title">LiteStats 统计系统</div><div class="error" id="error"></div><div class="form-group"><label>用户名</label><input type="text" id="username" placeholder="请输入用户名"></div><div class="form-group"><label>密码</label><input type="password" id="password" placeholder="请输入密码"></div><button class="btn" onclick="login()">登 录</button></div><script>document.getElementById('password').addEventListener('keypress',function(e){if(e.key==='Enter')login();});async function login(){const username=document.getElementById('username').value;const password=document.getElementById('password').value;const error=document.getElementById('error');if(!username||!password){error.textContent='请输入用户名和密码';error.style.display='block';return;}try{const resp=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});if(resp.ok){window.location.href='/';}else{const data=await resp.json();error.textContent=data.detail||'登录失败';error.style.display='block';}}catch(e){error.textContent='网络错误';error.style.display='block';}}</script></body></html>'''

@app.get("/", response_class=HTMLResponse)
async def dashboard(session_id: str = Cookie(None)):
    if not verify_session(session_id): return RedirectResponse(url="/login", status_code=302)
    with open("/app/frontend/index.html", "r", encoding="utf-8") as f: return f.read()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
MAINPY

    # 前端 index.html
    curl -sL "https://raw.githubusercontent.com/my9app/tongji/main/frontend/index.html" -o frontend/index.html 2>/dev/null || cat > frontend/index.html << 'HTMLEOF'
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>LiteStats</title><script src="https://cdn.jsdelivr.net/npm/chart.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}:root{--primary:#6366f1;--bg:#f1f5f9;--sidebar:#1e293b;--card:#fff;--text:#1e293b;--text-light:#64748b;--border:#e2e8f0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);display:flex;min-height:100vh}.sidebar{width:280px;background:var(--sidebar);color:#fff;display:flex;flex-direction:column;position:fixed;height:100vh;overflow:hidden}.sidebar-header{padding:20px;border-bottom:1px solid rgba(255,255,255,0.1)}.logo{font-size:24px;font-weight:700}.overview-stats{padding:20px;border-bottom:1px solid rgba(255,255,255,0.1)}.overview-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.overview-item{background:rgba(255,255,255,0.1);padding:12px;border-radius:8px;text-align:center}.overview-value{font-size:20px;font-weight:700}.overview-label{font-size:11px;opacity:0.7;margin-top:4px}.site-list{flex:1;overflow-y:auto;padding:10px}.site-group{margin-bottom:15px}.group-title{font-size:11px;text-transform:uppercase;opacity:0.5;padding:10px 10px 5px;letter-spacing:1px}.site-item{padding:12px 15px;border-radius:8px;cursor:pointer;transition:background 0.2s;display:flex;justify-content:space-between;align-items:center}.site-item:hover{background:rgba(255,255,255,0.1)}.site-item.active{background:var(--primary)}.site-name{font-weight:500;margin-bottom:2px}.site-domain{font-size:12px;opacity:0.6}.site-stats{text-align:right}.site-pv{font-size:14px;font-weight:600}.site-uv{font-size:11px;opacity:0.6}.sidebar-footer{padding:15px;border-top:1px solid rgba(255,255,255,0.1)}.btn-add{width:100%;padding:12px;background:var(--primary);color:#fff;border:none;border-radius:8px;font-size:14px;cursor:pointer;font-weight:500}.user-info{display:flex;justify-content:space-between;align-items:center;margin-top:10px;padding-top:10px;border-top:1px solid rgba(255,255,255,0.1)}.user-name{font-size:13px;opacity:0.7}.btn-logout{background:none;border:none;color:#fff;opacity:0.7;cursor:pointer;font-size:12px}.main{flex:1;margin-left:280px;padding:30px}.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:30px}.page-title{font-size:24px;font-weight:600}.period-buttons{display:flex;gap:5px}.period-buttons button{padding:8px 16px;background:#fff;color:var(--text);border:1px solid var(--border);border-radius:8px;cursor:pointer;font-size:13px}.period-buttons button.active{background:var(--primary);color:#fff;border-color:var(--primary)}.stats-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;margin-bottom:30px}.stat-card{background:var(--card);border-radius:12px;padding:25px;box-shadow:0 1px 3px rgba(0,0,0,0.1)}.stat-icon{width:48px;height:48px;border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:24px;margin-bottom:15px}.stat-icon.blue{background:#eff6ff;color:#3b82f6}.stat-icon.green{background:#ecfdf5;color:#10b981}.stat-icon.orange{background:#fff7ed;color:#f97316}.stat-icon.purple{background:#f5f3ff;color:#8b5cf6}.stat-label{font-size:14px;color:var(--text-light);margin-bottom:8px}.stat-value{font-size:32px;font-weight:700}.charts-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:30px}.chart-full{grid-column:1/-1}.card{background:var(--card);border-radius:12px;padding:25px;box-shadow:0 1px 3px rgba(0,0,0,0.1)}.card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}.card-title{font-size:16px;font-weight:600}.chart-container{position:relative;height:300px}.data-table{width:100%;border-collapse:collapse}.data-table th,.data-table td{padding:12px;text-align:left;border-bottom:1px solid var(--border)}.data-table th{font-weight:500;color:var(--text-light);font-size:12px;text-transform:uppercase}.progress-bar{width:100%;height:6px;background:var(--border);border-radius:3px;overflow:hidden}.progress-fill{height:100%;background:var(--primary);border-radius:3px}.realtime-list{max-height:350px;overflow-y:auto}.realtime-item{display:flex;align-items:center;padding:10px 0;border-bottom:1px solid var(--border);gap:12px}.device-icon{width:36px;height:36px;background:var(--bg);border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:18px}.realtime-info{flex:1}.realtime-path{font-weight:500}.realtime-meta{font-size:12px;color:var(--text-light)}.modal{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.5);z-index:1000;align-items:center;justify-content:center}.modal.active{display:flex}.modal-content{background:#fff;padding:30px;border-radius:16px;max-width:500px;width:90%}.modal-title{font-size:20px;font-weight:600;margin-bottom:20px}.form-group{margin-bottom:20px}.form-group label{display:block;margin-bottom:8px;font-weight:500}.form-group input,.form-group textarea{width:100%;padding:12px;border:1px solid var(--border);border-radius:8px;font-size:14px}.modal-actions{display:flex;gap:10px;justify-content:flex-end}.btn-primary{background:var(--primary);color:#fff;border:none;padding:12px 24px;border-radius:8px;cursor:pointer}.btn-secondary{background:#fff;color:var(--text);border:1px solid var(--border);padding:12px 24px;border-radius:8px;cursor:pointer}.btn-danger{background:#ef4444;color:#fff;border:none;padding:12px 24px;border-radius:8px;cursor:pointer}.code-block{background:#1e293b;color:#e2e8f0;padding:15px;border-radius:8px;font-family:monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;margin:15px 0}@media(max-width:768px){.sidebar{display:none}.main{margin-left:0}.stats-grid{grid-template-columns:1fr}.charts-grid{grid-template-columns:1fr}}</style></head><body><aside class="sidebar"><div class="sidebar-header"><div class="logo">📊 LiteStats</div></div><div class="overview-stats"><div class="overview-grid"><div class="overview-item"><div class="overview-value" id="totalTodayPV">0</div><div class="overview-label">今日 PV</div></div><div class="overview-item"><div class="overview-value" id="totalTodayUV">0</div><div class="overview-label">今日 UV</div></div><div class="overview-item"><div class="overview-value" id="totalSites">0</div><div class="overview-label">站点数</div></div><div class="overview-item"><div class="overview-value" id="totalOnline">0</div><div class="overview-label">当前在线</div></div></div></div><div class="site-list" id="siteList"></div><div class="sidebar-footer"><button class="btn-add" onclick="showAddSiteModal()">+ 添加站点</button><div class="user-info"><span class="user-name" id="userName">管理员</span><button class="btn-logout" onclick="logout()">退出登录</button></div></div></aside><main class="main"><div class="topbar"><h1 class="page-title" id="pageTitle">选择站点</h1><div class="period-buttons"><button data-period="24h">24小时</button><button data-period="7d" class="active">7天</button><button data-period="30d">30天</button><button data-period="90d">90天</button></div></div><div class="stats-grid"><div class="stat-card"><div class="stat-icon blue">👁️</div><div class="stat-label">页面浏览量 (PV)</div><div class="stat-value" id="totalPV">0</div></div><div class="stat-card"><div class="stat-icon green">👤</div><div class="stat-label">独立访客 (UV)</div><div class="stat-value" id="totalUV">0</div></div><div class="stat-card"><div class="stat-icon orange">🟢</div><div class="stat-label">当前在线</div><div class="stat-value" id="onlineCount">0</div></div><div class="stat-card"><div class="stat-icon purple">📄</div><div class="stat-label">平均页面/访客</div><div class="stat-value" id="avgPages">0</div></div></div><div class="charts-grid"><div class="card chart-full"><div class="card-header"><div class="card-title">📈 访问趋势</div></div><div class="chart-container"><canvas id="trendChart"></canvas></div></div><div class="card"><div class="card-header"><div class="card-title">🖥️ 设备分布</div></div><div class="chart-container"><canvas id="deviceChart"></canvas></div></div><div class="card"><div class="card-header"><div class="card-title">🌐 浏览器分布</div></div><div class="chart-container"><canvas id="browserChart"></canvas></div></div></div><div class="charts-grid"><div class="card"><div class="card-header"><div class="card-title">🔥 热门页面</div></div><table class="data-table" id="pagesTable"><thead><tr><th>页面</th><th>访问</th><th>占比</th></tr></thead><tbody></tbody></table></div><div class="card"><div class="card-header"><div class="card-title">🔗 来源</div></div><table class="data-table" id="sourcesTable"><thead><tr><th>来源</th><th>访问</th><th>占比</th></tr></thead><tbody></tbody></table></div></div><div class="charts-grid"><div class="card"><div class="card-header"><div class="card-title">🌍 国家</div></div><table class="data-table" id="countriesTable"><thead><tr><th>国家</th><th>访问</th><th>占比</th></tr></thead><tbody></tbody></table></div><div class="card"><div class="card-header"><div class="card-title">⚡ 实时</div></div><div class="realtime-list" id="realtimeList"><p style="text-align:center;color:#999;padding:40px">暂无数据</p></div></div></div></main><div class="modal" id="addSiteModal"><div class="modal-content"><div class="modal-title">添加站点</div><div class="form-group"><label>名称</label><input type="text" id="siteName" placeholder="我的网站"></div><div class="form-group"><label>域名</label><input type="text" id="siteDomain" placeholder="example.com"></div><div class="form-group"><label>分组</label><input type="text" id="siteGroup" placeholder="生产环境"></div><div class="form-group"><label>备注</label><textarea id="siteNotes" placeholder="说明..."></textarea></div><div class="modal-actions"><button class="btn-secondary" onclick="hideModal('addSiteModal')">取消</button><button class="btn-primary" onclick="addSite()">添加</button></div></div></div><div class="modal" id="siteDetailModal"><div class="modal-content"><div class="modal-title">站点设置</div><div class="form-group"><label>名称</label><input type="text" id="editSiteName"></div><div class="form-group"><label>分组</label><input type="text" id="editSiteGroup"></div><div class="form-group"><label>备注</label><textarea id="editSiteNotes"></textarea></div><div class="form-group"><label>追踪代码</label><div class="code-block" id="siteTrackingCode"></div><button class="btn-secondary" style="width:100%;margin-top:10px" onclick="copyCode()">复制代码</button></div><div class="modal-actions"><button class="btn-danger" onclick="deleteSite()">删除</button><button class="btn-secondary" onclick="hideModal('siteDetailModal')">取消</button><button class="btn-primary" onclick="updateSite()">保存</button></div></div></div><script>let currentSite=null,currentPeriod='7d',sites=[],trendChart=null,deviceChart=null,browserChart=null;const API=location.origin;document.addEventListener('DOMContentLoaded',async function(){const auth=await fetch('/api/check-auth').then(r=>r.json());if(!auth.authenticated){window.location.href='/login';return;}document.getElementById('userName').textContent=auth.username;loadOverview();loadSites();document.querySelectorAll('.period-buttons button').forEach(btn=>{btn.addEventListener('click',function(){document.querySelectorAll('.period-buttons button').forEach(b=>b.classList.remove('active'));this.classList.add('active');currentPeriod=this.dataset.period;if(currentSite)loadStats();});});setInterval(loadRealtime,30000);setInterval(loadOverview,60000);});async function loadOverview(){const d=await fetch('/api/overview').then(r=>r.json());document.getElementById('totalTodayPV').textContent=d.today_pv.toLocaleString();document.getElementById('totalTodayUV').textContent=d.today_uv.toLocaleString();document.getElementById('totalSites').textContent=d.site_count;document.getElementById('totalOnline').textContent=d.online;}async function loadSites(){sites=await fetch('/api/sites').then(r=>r.json());renderSiteList();if(sites.length>0&&!currentSite)selectSite(sites[0]);}function renderSiteList(){const c=document.getElementById('siteList');const g={};sites.forEach(s=>{const gn=s.group_name||'未分组';if(!g[gn])g[gn]=[];g[gn].push(s);});let h='';for(const[gn,gs]of Object.entries(g)){h+=`<div class="site-group"><div class="group-title">${gn}</div>`;gs.forEach(s=>{const a=currentSite&&currentSite.id===s.id;h+=`<div class="site-item ${a?'active':''}" onclick='selectSite(${JSON.stringify(s)})'><div><div class="site-name">${s.name}</div><div class="site-domain">${s.domain}</div></div><div class="site-stats"><div class="site-pv">${s.today_pv||0}</div><div class="site-uv">${s.today_uv||0} UV</div></div></div>`;});h+=`</div>`;}c.innerHTML=h||'<p style="text-align:center;color:#999;padding:40px">暂无站点</p>';}function selectSite(s){currentSite=s;document.getElementById('pageTitle').textContent=s.name;renderSiteList();loadStats();}async function loadStats(){if(!currentSite)return;const d=await fetch(`/api/stats/${currentSite.id}?period=${currentPeriod}`).then(r=>r.json());document.getElementById('totalPV').textContent=d.summary.pv.toLocaleString();document.getElementById('totalUV').textContent=d.summary.uv.toLocaleString();document.getElementById('avgPages').textContent=d.summary.uv>0?(d.summary.pv/d.summary.uv).toFixed(1):'0';updateTrendChart(d.daily);updateDeviceChart(d.devices);updateBrowserChart(d.browsers);updateTable('pagesTable',d.pages,'path','views',d.summary.pv);updateTable('sourcesTable',d.sources,'source','count',d.summary.pv);updateTable('countriesTable',d.countries,'country','count',d.summary.pv);loadRealtime();}async function loadRealtime(){if(!currentSite)return;const d=await fetch(`/api/realtime/${currentSite.id}`).then(r=>r.json());document.getElementById('onlineCount').textContent=d.online;const l=document.getElementById('realtimeList');if(d.recent.length===0){l.innerHTML='<p style="text-align:center;color:#999;padding:40px">暂无数据</p>';return;}l.innerHTML=d.recent.map(i=>`<div class="realtime-item"><div class="device-icon">${i.device==='Mobile'?'📱':'💻'}</div><div class="realtime-info"><div class="realtime-path">${i.path}</div><div class="realtime-meta">${i.country||'未知'} · ${i.timestamp}</div></div></div>`).join('');}function updateTrendChart(d){const ctx=document.getElementById('trendChart').getContext('2d');if(trendChart)trendChart.destroy();trendChart=new Chart(ctx,{type:'line',data:{labels:d.map(x=>x.date),datasets:[{label:'PV',data:d.map(x=>x.pv),borderColor:'#6366f1',backgroundColor:'rgba(99,102,241,0.1)',fill:true,tension:0.4},{label:'UV',data:d.map(x=>x.uv),borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.1)',fill:true,tension:0.4}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'top'}},scales:{y:{beginAtZero:true}}}});}function updateDeviceChart(d){const ctx=document.getElementById('deviceChart').getContext('2d');if(deviceChart)deviceChart.destroy();deviceChart=new Chart(ctx,{type:'doughnut',data:{labels:d.map(x=>x.device),datasets:[{data:d.map(x=>x.count),backgroundColor:['#6366f1','#10b981','#f59e0b']}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'bottom'}}}});}function updateBrowserChart(d){const ctx=document.getElementById('browserChart').getContext('2d');if(browserChart)browserChart.destroy();browserChart=new Chart(ctx,{type:'doughnut',data:{labels:d.map(x=>x.browser),datasets:[{data:d.map(x=>x.count),backgroundColor:['#6366f1','#10b981','#f59e0b','#ef4444','#8b5cf6','#ec4899']}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'bottom'}}}});}function updateTable(tid,d,lk,vk,t){const tb=document.querySelector(`#${tid} tbody`);if(d.length===0){tb.innerHTML='<tr><td colspan="3" style="text-align:center;color:#999">暂无</td></tr>';return;}tb.innerHTML=d.map(i=>{const p=t>0?(i[vk]/t*100).toFixed(1):0;return`<tr><td>${i[lk]||'直接'}</td><td>${i[vk]}</td><td><div class="progress-bar"><div class="progress-fill" style="width:${p}%"></div></div></td></tr>`;}).join('');}function showAddSiteModal(){document.getElementById('addSiteModal').classList.add('active');}function hideModal(id){document.getElementById(id).classList.remove('active');}async function addSite(){const n=document.getElementById('siteName').value.trim(),d=document.getElementById('siteDomain').value.trim(),g=document.getElementById('siteGroup').value.trim(),t=document.getElementById('siteNotes').value.trim();if(!n||!d){alert('请填写名称和域名');return;}const r=await fetch('/api/sites',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,domain:d,group_name:g,notes:t})});if(r.ok){hideModal('addSiteModal');document.getElementById('siteName').value='';document.getElementById('siteDomain').value='';document.getElementById('siteGroup').value='';document.getElementById('siteNotes').value='';loadSites();loadOverview();}else{const e=await r.json();alert(e.detail||'失败');}}function showSiteDetail(){if(!currentSite)return;document.getElementById('editSiteName').value=currentSite.name;document.getElementById('editSiteGroup').value=currentSite.group_name||'';document.getElementById('editSiteNotes').value=currentSite.notes||'';document.getElementById('siteTrackingCode').textContent=`<script>\nwindow.LITESTATS_URL = '${API}';\nwindow.LITESTATS_TOKEN = '${currentSite.token}';\n<\/script>\n<script src="${API}/tracker.js"><\/script>`;document.getElementById('siteDetailModal').classList.add('active');}async function updateSite(){if(!currentSite)return;await fetch(`/api/sites/${currentSite.id}`,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:document.getElementById('editSiteName').value.trim(),group_name:document.getElementById('editSiteGroup').value.trim(),notes:document.getElementById('editSiteNotes').value.trim()})});hideModal('siteDetailModal');loadSites();}async function deleteSite(){if(!currentSite)return;if(!confirm(`确定删除 "${currentSite.name}"？`))return;await fetch(`/api/sites/${currentSite.id}`,{method:'DELETE'});currentSite=null;hideModal('siteDetailModal');loadSites();loadOverview();}function copyCode(){navigator.clipboard.writeText(document.getElementById('siteTrackingCode').textContent).then(()=>alert('已复制'));}async function logout(){await fetch('/api/logout',{method:'POST'});window.location.href='/login';}document.querySelectorAll('.modal').forEach(m=>{m.addEventListener('click',function(e){if(e.target===this)this.classList.remove('active');});});document.getElementById('siteList').addEventListener('dblclick',function(e){if(e.target.closest('.site-item')&&currentSite)showSiteDetail();});</script></body></html>
HTMLEOF

    # Dockerfile
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

    # docker-compose.yml
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
      - ADMIN_USER=${ADMIN_USER}
      - ADMIN_PASS=${ADMIN_PASS}
COMPOSEFILE

    # .env 文件
    cat > .env << ENVFILE
PORT=${PORT}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
ENVFILE

    echo -e "${GREEN}✓ 项目文件创建完成${NC}"
}

start_service() {
    echo -e "${YELLOW}[4/4] 启动服务...${NC}"
    
    docker compose up -d --build 2>/dev/null || docker-compose up -d --build
    
    sleep 3
    
    if docker ps | grep -q litestats; then
        echo -e "${GREEN}✓ LiteStats 启动成功!${NC}"
    else
        echo -e "${RED}启动失败，请检查日志：docker logs litestats${NC}"
        exit 1
    fi
}

show_info() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         🎉 安装完成！                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  访问地址: ${BLUE}http://${LOCAL_IP}:${PORT}${NC}"
    echo ""
    echo -e "  登录信息:"
    echo -e "    用户名: ${YELLOW}${ADMIN_USER}${NC}"
    echo -e "    密  码: ${YELLOW}${ADMIN_PASS}${NC}"
    echo ""
    echo -e "  管理命令:"
    echo -e "    查看日志: ${YELLOW}docker logs -f litestats${NC}"
    echo -e "    重启服务: ${YELLOW}cd /opt/litestats && docker compose restart${NC}"
    echo -e "    修改密码: ${YELLOW}编辑 /opt/litestats/.env 后重启${NC}"
    echo ""
    echo -e "  数据目录: /opt/litestats/data"
    echo ""
    echo -e "${RED}  ⚠️  请及时修改默认密码！${NC}"
    echo ""
}

main() {
    check_docker
    setup_project
    download_files
    start_service
    show_info
}

main
