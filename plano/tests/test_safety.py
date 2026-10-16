#!/usr/bin/env python3
"""Testes de falha/invariantes; nenhum comando do cluster ou host real e executado."""
import json, os, pathlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class StorageGuard(unittest.TestCase):
    def guard(self, volume, pv=None, policy=None, infra=False):
        with tempfile.TemporaryDirectory() as t:
            p=pathlib.Path(t)
            pod={'metadata':{'namespace':'app','name':'db','ownerReferences':[{'kind':'DaemonSet' if infra else 'StatefulSet'}]},'spec':{'volumes':[dict(name='data',**volume)]},'status':{'phase':'Running'}}
            files={'pods':{'items':[pod]},'pvcs':{'items':[{'metadata':{'name':'data','namespace':'app'},'spec':{'volumeName':'pv'}}]},'pvs':{'items':[{'metadata':{'name':'pv'},'spec':pv}]} if pv else {'items':[]},'policy':policy or {'allowEmptyDirDeletion':False,'remoteCSIDrivers':[],'hostPathAllowlist':[]}}
            for n,v in files.items(): (p/n).write_text(json.dumps(v))
            r=subprocess.run(['jq','-r','--slurpfile','pvcs',str(p/'pvcs'),'--slurpfile','pvs',str(p/'pvs'),'--slurpfile','policy',str(p/'policy'),'-f',str(ROOT/'scripts/storage-guard.jq'),str(p/'pods')],text=True,capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            return r.stdout.strip()
    def test_local_pv_blocked(self): self.assertIn('local/hostPath',self.guard({'persistentVolumeClaim':{'claimName':'data'}},{'local':{'path':'/data'}}))
    def test_longhorn_allowed(self): self.assertEqual('',self.guard({'persistentVolumeClaim':{'claimName':'data'}},{'csi':{'driver':'driver.longhorn.io'}}))
    def test_missing_pv_blocked(self): self.assertIn('nao resolvido',self.guard({'persistentVolumeClaim':{'claimName':'data'}}))
    def test_emptydir_default_blocked(self): self.assertIn('emptyDir',self.guard({'emptyDir':{}}))
    def test_emptydir_lab_authorization(self): self.assertEqual('',self.guard({'emptyDir':{}},policy={'allowEmptyDirDeletion':True,'remoteCSIDrivers':[],'hostPathAllowlist':[]}))
    def test_application_hostpath_blocked(self): self.assertIn('hostPath',self.guard({'hostPath':{'path':'/data'}}))
    def test_daemonset_hostpath_kept(self): self.assertEqual('',self.guard({'hostPath':{'path':'/proc'}},infra=True))
    def test_daemonset_local_pvc_still_blocked(self): self.assertIn('local/hostPath',self.guard({'persistentVolumeClaim':{'claimName':'data'}},{'local':{'path':'/data'}},infra=True))
    def test_inline_csi_blocked(self): self.assertIn('CSI inline',self.guard({'csi':{'driver':'unreviewed'}}))

class HostWorker(unittest.TestCase):
    def run_worker(self, mode='nochange', pending=False, allow=True):
        t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        base=pathlib.Path(t.name); bindir=base/'bin';bindir.mkdir(); statebase=base/'state';state=statebase/'abc';state.mkdir(parents=True)
        (base/'current').write_text('100');(base/'target').write_text('101' if pending else '100')
        mocks={
            'systemctl': '''#!/bin/bash
if [[ $1 == show ]]; then echo inactive; elif [[ $1 == is-active ]]; then [[ $MODE == server* ]]; elif [[ $1 == reboot ]]; then touch "$CASE/reboot"; kill -TERM "$PPID"; fi
''',
            'btrfs': '''#!/bin/bash
if [[ $1 == inspect-internal ]]; then cat "$CASE/current"; else echo "ID $(cat "$CASE/target") gen 1 top level 1 path snapshot"; fi
''',
            'transactional-update': '''#!/bin/bash
touch "$CASE/update"
case "$MODE" in fail) exit 42;; change) echo 101 > "$CASE/target";; esac
''',
            'rke2': '#!/bin/bash\necho "$*" > "$CASE/snapshot"\n[[ $MODE != serverfail ]]\n',
            'sleep': '#!/bin/bash\nexit 0\n',
            'sync': '#!/bin/bash\nexit 0\n',
        }
        for name,body in mocks.items(): f=bindir/name;f.write_text(body);f.chmod(0o755)
        # Redireciona somente o diretorio de estado no exemplar de teste.
        script=(ROOT/'scripts/host-worker.sh').read_text().replace('/var/lib/suc-os',str(statebase))
        worker=base/'worker.sh';worker.write_text(script)
        env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'],CASE=str(base),MODE=mode)
        r=subprocess.run(['bash',str(worker),str(state),'micro62',str(allow).lower()],env=env,capture_output=True,text=True,timeout=10)
        return r,base,state
    def test_server_snapshot_before_update(self):
        r,b,s=self.run_worker('serverok');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('etcd-snapshot save --name pre-os-abc',(b/'snapshot').read_text());self.assertTrue((b/'update').exists())
    def test_server_snapshot_failure_blocks_update(self):
        r,b,s=self.run_worker('serverfail');self.assertNotEqual(r.returncode,0);self.assertFalse((b/'update').exists());self.assertFalse((b/'reboot').exists());self.assertIn('comando=rke2',r.stderr)
    def test_nochange_never_reboots(self):
        r,b,s=self.run_worker(); self.assertEqual(r.returncode,0,r.stderr); self.assertFalse((b/'reboot').exists());self.assertEqual((s/'phase').read_text().strip(),'done'); self.assertIn('NAO sera reiniciado',r.stdout)
    def test_update_failure_stops_without_reboot(self):
        r,b,s=self.run_worker('fail');self.assertEqual(r.returncode,42);self.assertFalse((b/'reboot').exists());self.assertEqual((s/'phase').read_text().strip(),'failed')
    def test_changed_snapshot_waits_for_real_reboot(self):
        r,b,s=self.run_worker('change');self.assertTrue((b/'reboot').exists());self.assertEqual((s/'phase').read_text().strip(),'reboot-pending');self.assertNotEqual(r.returncode,0)
    def test_pending_snapshot_needs_explicit_policy(self):
        r,b,s=self.run_worker(pending=True,allow=False);self.assertNotEqual(r.returncode,0);self.assertFalse((b/'update').exists());self.assertFalse((b/'reboot').exists());self.assertEqual((s/'phase').read_text().strip(),'failed')
    def test_pending_snapshot_never_overwritten(self):
        r,b,s=self.run_worker(pending=True);self.assertFalse((b/'update').exists());self.assertTrue((b/'reboot').exists());self.assertEqual((s/'result').read_text().strip(),'pending-snapshot-activated')

class RebootInterruption(unittest.TestCase):
    def simulate(self, explicit_failure):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);p=pathlib.Path(t.name)
        (p/'phase').write_text('reboot-pending')
        script='source "$COMMON"\nLOCAL_STATE="$CASE"\nOWNED=true\ngate_phase() { echo "$1" > "$CASE/gate-changed"; }\n'
        script+=('fail "timeout real"\n' if explicit_failure else 'exit 143\n')
        env=dict(os.environ,COMMON=str(ROOT/'scripts/common.sh'),CASE=str(p),SYSTEM_UPGRADE_NODE_NAME='node1',SYSTEM_UPGRADE_PLAN_LATEST_HASH='abc',SYSTEM_UPGRADE_PLAN_NAME='os-maintenance',SYSTEM_UPGRADE_PLAN_LATEST_VERSION='test',PLAN_NAMESPACE='cattle-system')
        r=subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
        return r,p
    def test_expected_reboot_keeps_resumable_gate(self):
        r,p=self.simulate(False);self.assertEqual(r.returncode,143);self.assertFalse((p/'gate-changed').exists())
    def test_explicit_failure_still_latches(self):
        r,p=self.simulate(True);self.assertNotEqual(r.returncode,0);self.assertEqual((p/'gate-changed').read_text().strip(),'failed')

if __name__=='__main__': unittest.main(verbosity=2)
