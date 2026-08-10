"""项目配置包。

使用 pymysql 作为 Django MySQL 后端的纯 Python 驱动：
``install_as_MySQLdb()`` 让 ``django.db.backends.mysql`` 后端复用 pymysql
（Windows 下免编译，避免 mysqlclient 的 MSVC 依赖）。
"""
import pymysql

pymysql.install_as_MySQLdb()

default_app_config = None
