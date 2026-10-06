#!/usr/bin/env python3
"""Добавляет файл из ios/Runner/ в проект Xcode как ресурс цели Runner.

Нужен приложениям, у которых папка ios/ создаётся `flutter create` (store, courier):
так в сборку попадает PrivacyInfo.xcprivacy — без правки project.pbxproj вручную.

    python3 ../scripts/ios_add_resource.py ios PrivacyInfo.xcprivacy

Повторный запуск ничего не меняет. Если структура project.pbxproj не похожа на
шаблон Flutter — скрипт падает с понятной ошибкой, а не портит файл.
"""
import hashlib
import re
import sys

FILE_TYPES = {
    '.xcprivacy': 'text.xml',
    '.plist': 'text.plist.xml',
    '.json': 'text.json',
}


def die(msg):
    sys.exit(f'ios_add_resource: {msg}')


def new_id(seed, used):
    """24 шестнадцатеричных символа, как у Xcode; стабильно для одного и того же файла."""
    n = 0
    while True:
        h = hashlib.sha1(f'{seed}:{n}'.encode()).hexdigest()[:24].upper()
        if h not in used:
            used.add(h)
            return h
        n += 1


def insert_before(s, marker, text):
    i = s.find(marker)
    if i < 0:
        die(f'не найдено «{marker}» в project.pbxproj')
    return s[:i] + text + s[i:]


def main():
    if len(sys.argv) != 3:
        die('использование: ios_add_resource.py <папка ios> <имя файла в Runner/>')
    ios, name = sys.argv[1], sys.argv[2]
    path = f'{ios}/Runner.xcodeproj/project.pbxproj'
    s = open(path, encoding='utf-8').read()

    if re.search(r'/\* ' + re.escape(name) + r' in Resources \*/', s):
        print(f'{name}: уже в проекте')
        return

    used = set(re.findall(r'\b[0-9A-F]{24}\b', s))
    ref = new_id(f'{name}:ref', used)
    build = new_id(f'{name}:build', used)
    ext = name[name.rfind('.'):] if '.' in name else ''
    ftype = FILE_TYPES.get(ext, 'text')

    # 1. Ссылка на файл и файл сборки.
    s = insert_before(s, '/* End PBXBuildFile section */',
                      f'\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; '
                      f'fileRef = {ref} /* {name} */; }};\n')
    s = insert_before(s, '/* End PBXFileReference section */',
                      f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; '
                      f'path = {name}; sourceTree = "<group>"; }};\n')

    # 2. Группа Runner (папка ios/Runner в навигаторе Xcode).
    m = re.search(r'/\* Runner \*/ = \{\s*isa = PBXGroup;\s*children = \(\n', s)
    if not m:
        die('не найдена группа Runner (PBXGroup)')
    s = s[:m.end()] + f'\t\t\t\t{ref} /* {name} */,\n' + s[m.end():]

    # 3. Фаза Resources цели Runner (не RunnerTests).
    t = re.search(r'/\* Runner \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);', s, re.S)
    if not t:
        die('не найдена цель Runner (PBXNativeTarget)')
    phase = re.search(r'([0-9A-F]{24}) /\* Resources \*/', t.group(1))
    if not phase:
        die('у цели Runner нет фазы Resources')
    m = re.search(re.escape(phase.group(1)) + r' /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;'
                  r'.*?files = \(\n', s, re.S)
    if not m:
        die('не найдена фаза PBXResourcesBuildPhase цели Runner')
    s = s[:m.end()] + f'\t\t\t\t{build} /* {name} in Resources */,\n' + s[m.end():]

    open(path, 'w', encoding='utf-8').write(s)
    print(f'{name}: добавлен в ресурсы Runner')


if __name__ == '__main__':
    main()
