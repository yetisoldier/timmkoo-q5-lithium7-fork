"""Remove unsupported Q5 features without deleting unrelated permissions."""
import xml.etree.ElementTree as ET

UNSUPPORTED = {
    'android.hardware.sensor.compass',
    'android.hardware.sensor.gyroscope',
}

def prune(data):
    root = ET.fromstring(data)
    removed = []
    for parent in root.iter():
        for child in list(parent):
            name = child.get('name', '')
            if child.tag == 'feature' and (name.startswith('android.hardware.camera') or name in UNSUPPORTED):
                removed.append(name)
                parent.remove(child)
    if not removed:
        return data, removed
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True) + b'\n', removed
