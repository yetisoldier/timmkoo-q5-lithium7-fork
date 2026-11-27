#!/usr/bin/env python3
"""Run the real recovery shell script with deterministic control-socket replies."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile

MOCK = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['Q5_TEST_STATE']);s=json.loads(p.read_text())
name=Path(sys.argv[0]).name;args=sys.argv[1:]
if name=='getprop':
 print('stopped' if s['case']=='off' or (s['case']=='turned_off' and s['ticks']>=4) else 'running')
elif name=='sleep':s['ticks']+=1
elif name=='log':pass
elif name=='wpa_cli':
 assert args[:2]==['-i','wlan0'];args=args[2:];cmd=args[0]
 if cmd=='status':
  success=s['case']=='connected' or (s['case']=='recover' and s['retries']>=1) or (s['case']=='recover_second' and s['retries']>=2)
  print('wpa_state=COMPLETED' if success else 'wpa_state=ASSOCIATED')
 elif cmd=='list_networks':
  print('network id\tssid\tbssid\tflags')
  if s['case']!='no_profiles':print('0\tSaved\tany\t'+('[DISABLED]' if s['case']=='disabled' else ''))
 elif cmd=='get_network':
  assert args[1:]==['0','key_mgmt']
  print({'enterprise':'WPA-EAP','wps_pin':'WPS'}.get(s['case'],'WPA-PSK'))
 elif cmd=='wps_get_status':print('PBC Status: '+('Active' if s['case']=='wps' else 'Disabled'))
 elif cmd=='reassociate':s['retries']+=1;print('OK')
 else:raise AssertionError('Disallowed control command: '+cmd)
else:raise AssertionError(name)
p.write_text(json.dumps(s))
'''


def main():
    script = Path(__file__).resolve().parents[1] / 'build/q5-wifi-reconnect.sh'
    init = script.with_name('q5-wifi-address.rc').read_text()
    services = re.findall(r'^service (\S+) ', init, re.M)
    assert services and all(re.fullmatch(r'[a-zA-Z0-9_-]{1,16}', s) for s in services)
    assert all(s in services for s in re.findall(r'^\s+(?:start|stop) (\S+)', init, re.M))
    cases = {'connected': 0, 'recover': 1, 'recover_second': 2, 'never': 2,
             'off': 0, 'turned_off': 0, 'no_profiles': 0, 'disabled': 0,
             'enterprise': 0, 'wps': 0, 'wps_pin': 0}
    with tempfile.TemporaryDirectory(prefix='q5-wifi-recovery-') as tmp:
        tmp = Path(tmp)
        for name in ['getprop', 'sleep', 'log', 'wpa_cli']:
            target = tmp / name
            target.write_text(MOCK)
            target.chmod(0o755)
        state = tmp / 'state.json'
        env = dict(os.environ, PATH=str(tmp) + ':' + os.environ['PATH'],
                   Q5_TEST_STATE=str(state))
        for case, count in cases.items():
            state.write_text(json.dumps({'case': case, 'ticks': 0, 'retries': 0}))
            subprocess.run(['bash', str(script)], check=True, env=env, timeout=15)
            result = json.loads(state.read_text())
            assert result['retries'] == count, (case, result)
            assert result['ticks'] <= 30, (case, result)
    print('PASS: recovery/exits/budget, Wi-Fi off, disabled/no profiles, enterprise and WPS')


if __name__ == '__main__':
    main()
