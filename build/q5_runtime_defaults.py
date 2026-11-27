"""Restore original ART defaults and describe the Q5 as a Wi-Fi-only player."""
import re

ART_DEFAULTS = {
    'dalvik.vm.heapstartsize': ('8m', '5m'),
    'dalvik.vm.heapgrowthlimit': ('192m', '48m'),
    'dalvik.vm.heapsize': ('256m', '64m'),
    'dalvik.vm.dex2oat-filter': ('speed', 'interpret-only'),
}


def normalize_properties(data):
    for key, (original, obsolete) in ART_DEFAULTS.items():
        pattern = r'(?m)^' + re.escape(key) + r'=([^\r\n]*)\r?\n?'
        values = re.findall(pattern, data)
        assert values in ([original, obsolete], [original]), (key, values)
        seen = False
        def keep_original(match):
            nonlocal seen
            if seen:
                return ''
            seen = True
            return key + '=' + original + '\n'
        data = re.sub(pattern, keep_original, data)
    key = 'ro.radio.noril'
    pattern = r'(?m)^' + re.escape(key) + r'=.*$'
    assert len(re.findall(pattern, data)) <= 1
    return (re.sub(pattern, key + '=true', data) if re.search(pattern, data)
            else data.rstrip('\n') + '\n' + key + '=true\n')


def disable_service(data, name):
    """Add disabled to exactly one init service without editing its commands."""
    pattern = rb'(?m)^(service ' + re.escape(name.encode()) + rb' [^\n]+\n)((?:[ \t]+[^\n]*\n|\n)*)'
    matches = list(re.finditer(pattern, data))
    assert len(matches) == 1, name
    match = matches[0]
    if re.search(rb'(?m)^\s+disabled\s*$', match[2]):
        return data
    return data[:match.end(1)] + b'    disabled\n' + data[match.end(1):]
