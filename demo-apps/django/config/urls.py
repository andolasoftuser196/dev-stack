from django.urls import path

from demo.views import index

urlpatterns = [path("", index)]
