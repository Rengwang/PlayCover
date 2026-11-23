#!/usr/bin/env python3
"""Sequential same-build comparison; refuses to reuse a running user's application.

Build window-runner.swift and process-usage.c into --bin first. --manifest is a JSON
list of {label, path}; optional `states` overrides visible/active/hidden/restore.
Reports are local: paths, screenshots and running-process lists must not be published.
"""
import argparse
import json
import math
import plistlib
import os
import signal
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--bin', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=20, choices=range(5, 61))
    parser.add_argument('--rounds', type=int, default=2, choices=range(1, 6))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    runner = args.bin.resolve() / 'window-runner'
    usage = args.bin.resolve() / 'process-usage'
    manifest = json.loads(args.manifest.read_text())

    def command(*command_args):
        result = subprocess.run([str(runner), *map(str, command_args)], capture_output=True, text=True, timeout=65)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return json.loads(result.stdout)

    def save(path, value):
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    save(args.out / 'screens.json', command('screens'))
    results = []
    for trial in range(args.rounds):
        # Alternate order to limit systematic bias from warm caches and network startup.
        for case in manifest if trial % 2 == 0 else reversed(manifest):
            dest = args.out / f"{trial + 1}-{case['label']}"
            dest.mkdir(exist_ok=True)
            pid = None
            result = dict(case, trial=trial + 1, stages=[])
            try:
                launch = command('launch', case['path'])
                save(dest / 'launch.json', launch)
                pid = launch['pid']
                result['launch'] = launch
                if not launch['windows'] or not all(w['onTargetScreen'] for w in launch['windows']):
                    raise RuntimeError('Window was not placed on the target display')
                placement = command('resize', pid, 810, 720)
                save(dest / 'placement.json', placement)
                for state in case.get('states', ['visible', 'active', 'hidden', 'restore']):
                    if state != 'visible':
                        command('state', pid, state)
                    # Allow animations, startup work and App Nap eligibility to settle.
                    time.sleep(15 if state == 'hidden' else 6)
                    before = command('inspect', pid)
                    save(dest / f'{state}-before.json', before)
                    power_path = dest / f'{state}-power.plist'
                    power_error = (dest / f'{state}-power.stderr').open('w')
                    power = subprocess.Popen([
                        '/usr/bin/sudo', '-n', '/usr/bin/powermetrics', '-s', 'tasks,cpu_power,gpu_power',
                        '--show-process-gpu', '--show-process-energy', '--handle-invalid-values',
                        '-i', '1000', '-n', str(args.seconds), '-f', 'plist', '-o', str(power_path)
                    ], stdout=subprocess.DEVNULL, stderr=power_error)
                    try:
                        sample = json.loads(subprocess.check_output([str(usage), str(pid), str(args.seconds)], text=True))
                        power.wait(timeout=args.seconds + 10)
                    finally:
                        if power.poll() is None:
                            power.terminate()
                            power.wait(timeout=5)
                        power_error.close()
                    sample['state'] = state
                    sample['before'] = before
                    sample['after'] = command('inspect', pid)
                    if power.returncode == 0:
                        # powermetrics writes NUL-separated plists. Missing per-task GPU
                        # counters remain unavailable, rather than being reported as zero.
                        samples = [plistlib.loads(p) for p in power_path.read_bytes().split(b'\0') if p.strip()]
                        valid = [p for p in samples if not p.get('invalid', False)]
                        for key in ('cpu_power', 'gpu_power', 'combined_power'):
                            values = [(p.get('processor', {}).get(key), p.get('elapsed_ns', 0)) for p in valid]
                            values = [(v, w) for v, w in values if isinstance(v, (float, int)) and math.isfinite(v) and w > 0]
                            sample['system_' + key + '_mW'] = sum(v * w for v, w in values) / sum(w for _, w in values) if values else None
                        tasks = [t for p in valid for t in p.get('tasks', []) if t.get('pid') == pid]
                        sample['power_task_sample_count'] = len(tasks)
                        sample['power_task_gpu_fields'] = [{k: v for k, v in t.items() if 'gpu' in k} for t in tasks]
                    else:
                        sample['powermetrics_error'] = (dest / f'{state}-power.stderr').read_text()
                    save(dest / f'{state}-usage.json', sample)
                    result['stages'].append(sample)
                    print(f"{trial+1} {case['label']} {state}: cpu={sample['cpu_percent_one_core']:.2f}% "
                          f"footprint={sample['footprint_end_bytes']/1048576:.1f}MiB "
                          f"process={sample['attributed_mW']:.2f}mW active={sample['after']['active']}", flush=True)
            except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
                result['error'] = str(error)
                print(f"{case['label']}: {error}", flush=True)
            finally:
                if pid is not None:
                    try:
                        result['quit'] = command('quit', pid)
                        if not result['quit']['terminated']:
                            # Only clean up the exact process this invocation launched.
                            current = command('inspect', pid)
                            if current['executable'] != launch['executable']:
                                raise RuntimeError('PID executable changed; refusing cleanup')
                            os.kill(pid, signal.SIGTERM)
                            result['quit']['sentSIGTERM'] = True
                            time.sleep(1)
                            result['quit']['existsAfterSIGTERM'] = Path('/proc/' + str(pid)).exists() if Path('/proc').exists() else bool(
                                subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'pid='], capture_output=True).stdout.strip())
                    except (RuntimeError, subprocess.SubprocessError):
                        result['quit'] = {'terminated': False}
                results.append(result)
                save(args.out / 'results.json', results)


if __name__ == '__main__':
    main()
