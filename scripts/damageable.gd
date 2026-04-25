class_name Damageable
extends RefCounted
## Маркер-контракт «damageable» сущности. Сам класс не используется как наследник —
## три damageable-типа (Item, Tower, Enemy) живут на разных физических базах
## (RigidBody3D / CharacterBody3D × 2) и не могут разделять одно наследование.
## Этот файл существует ради ОДНОГО места, где формально записан протокол:
##
## Damageable-сущность ОБЯЗАНА:
##   - Иметь метод `take_damage(amount: float) -> void` (амоунт в HP).
##   - Эмитить сигнал `damaged(amount: float)` каждый раз при ненулевом приёме урона.
##   - Эмитить сигнал `destroyed` ровно один раз при переходе hp ≤ 0.
##   - Гарантировать идемпотентность: повторные take_damage после destroyed — no-op.
##
## Внешний код проверяет принадлежность через duck typing:
##     if entity.has_method("take_damage"): entity.take_damage(amount)
## Сильная типизация в GDScript невозможна без общего родителя.
##
## Текущие реализации: Item, Tower, Enemy (и его подклассы — Skeleton).
