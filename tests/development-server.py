"""Local UI fixture only: no external auth calls or emails. Not a production backend."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import json, shutil, time

PUBLIC = Path(__file__).resolve().parents[1] / 'docs'
PREVIEW = Path('/tmp/nova-sync-browser-fixture')
shutil.copytree(PUBLIC, PREVIEW, dirs_exist_ok=True)
(PREVIEW / 'sync-config.js').write_text("export const syncConfig = Object.freeze({url:'http://127.0.0.1:4173',publishableKey:'sb_publishable_LOCAL_TEST_ONLY'});\n")
ACCOUNTS = {'first@example.test':'00000000-0000-4000-8000-000000000001', 'second@example.test':'00000000-0000-4000-8000-000000000002'}
LIBRARIES = {}

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(PREVIEW), **kwargs)
    def log_message(self, *args): pass
    def reply(self, value, status=200):
        data=json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    def identity(self):
        token=self.headers.get('Authorization','').removeprefix('Bearer fixture-')
        return next(({'id':user,'email':email} for email,user in ACCOUNTS.items() if user==token),None)
    def session(self,email): return {'access_token':'fixture-'+ACCOUNTS[email],'refresh_token':'fixture-'+ACCOUNTS[email],'expires_at':time.time()+3600,'user':{'id':ACCOUNTS[email],'email':email}}
    def do_GET(self):
        path=urlparse(self.path)
        if path.path=='/auth/v1/user': return self.reply(self.identity() or {'msg':'Test sign-in required'},200 if self.identity() else 401)
        if path.path=='/rest/v1/nova_music_libraries':
            user=self.identity()
            if not user:return self.reply({'msg':'Test sign-in required'},401)
            requested=parse_qs(path.query).get('user_id',[''])[0]
            return self.reply([LIBRARIES[user['id']]] if requested=='eq.'+user['id'] and user['id'] in LIBRARIES else [])
        return super().do_GET()
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}');path=urlparse(self.path).path
        if path=='/auth/v1/otp':return self.reply({} if body.get('email') in ACCOUNTS else {'msg':'Use first@example.test or second@example.test. This is a local fixture.'},200 if body.get('email') in ACCOUNTS else 400)
        if path=='/auth/v1/verify':
            if body.get('email') not in ACCOUNTS or body.get('token')!='123456':return self.reply({'msg':'Local test code is 123456'},400)
            return self.reply(self.session(body['email']))
        if path=='/auth/v1/logout':return self.reply({})
        if path=='/rest/v1/rpc/save_nova_music_library':
            user=self.identity()
            if not user:return self.reply({'msg':'Test sign-in required'},401)
            current=LIBRARIES.get(user['id'],{'revision':0})
            if body.get('expected_revision')!=current['revision']:return self.reply({'conflict':True,'revision':current['revision']})
            revision=current['revision']+1;LIBRARIES[user['id']]={'revision':revision,'document':body['library_document']}
            return self.reply({'conflict':False,'revision':revision})
        return self.reply({'msg':'Unsupported test operation'},404)

if __name__=='__main__':
    print('Local account fixture ready. Test accounts only; no messages are sent.',flush=True)
    ThreadingHTTPServer(('127.0.0.1',4173),Handler).serve_forever()
