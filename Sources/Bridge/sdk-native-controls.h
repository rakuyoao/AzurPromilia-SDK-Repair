#include <stdarg.h>

typedef struct {uint32_t id,generation;void *widget;unsigned long long image_key;} NativeControl;
static NativeControl controls[2048];
static size_t control_count;
static uint32_t control_serial;
static void (*qt_object_name)(const void *,void *),(*qt_widget_style)(const void *,void *);
static const WCHAR *(*qt_string_utf16)(const void *);
static int (*qt_string_size)(const void *);
static bool (*qt_ancestor)(const void *,const void *),(*qt_enabled)(const void *);
static bool (*qt_attribute)(const void *,int);
static void *(*qt_parent)(const void *);
static void (*qt_button_text)(const void *,void *),(*qt_line_text)(const void *,void *),(*qt_placeholder)(const void *,void *),(*qt_label_text)(const void *,void *),(*qt_html)(const void *,void *);
static int (*qt_echo)(const void *);
static int (*qt_max_length)(const void *);
static void (*qt_alignment)(const void *,int *);
static bool (*qt_checked)(const void *);
static void (*qt_click)(void *),(*qt_set_text)(void *,const void *),(*qt_link)(void *,const void *);
static const void *(*qt_font)(const void *);
static void (*qt_font_family)(const void *,void *);
static int (*qt_font_pixels)(const void *);
static double (*qt_font_points)(const void *);
static bool (*qt_font_bold)(const void *);
static const void *(*qt_label_pixmap)(const void *);
typedef struct {int width,height;} QtSize;
static void (*qt_label_size_hint)(const void *,QtSize *);
static bool (*qt_pixmap_null)(const void *),(*qt_pixmap_save)(const void *,const void *,const char *,int);
static long long (*qt_pixmap_key)(const void *);
static void (*qt_resource_construct)(void *,const void *,const void *),(*qt_resource_destruct)(void *),(*qt_resource_children)(const void *,void *),(*qt_resource_bytes)(const void *,void *);
static bool (*qt_resource_dir)(const void *);
static void (*qt_locale_construct)(void *),(*qt_locale_destruct)(void *),(*qt_bytes_destruct)(void *);
static int (*qt_bytes_size)(const void *);
static const char *(*qt_bytes_data)(const void *);
static void (*qt_url_construct)(void *,const void *,int),(*qt_url_destruct)(void *),(*qt_anchor)(void *,const void *);
static void *(*qt_scrollbar)(const void *);
static int (*qt_slider_max)(const void *);
static void (*qt_slider_value)(void *,int);
static const char *(*qt_class_name)(const void *);
static LONG CALLBACK control_exception(EXCEPTION_POINTERS *exception)
{
    static LONG count;
    DWORD code=exception->ExceptionRecord->ExceptionCode;
    if((code==EXCEPTION_ACCESS_VIOLATION || code==EXCEPTION_ILLEGAL_INSTRUCTION) && InterlockedIncrement(&count)<=3) {
        FILE *file=_wfopen(L"C:\\FineWine\\native-control-exception.log",L"a");
        if(file) {
            MEMORY_BASIC_INFORMATION info;WCHAR name[1024]=L"";DWORD64 pc=exception->ContextRecord->Rip;
            if(VirtualQuery((void *)pc,&info,sizeof(info)))GetModuleFileNameW(info.AllocationBase,name,1024);
            fwprintf(file,L"code=%08lx module=%ls offset=%llx rcx=%llx rdx=%llx r8=%llx r9=%llx\n",code,name,(unsigned long long)(pc-(DWORD64)info.AllocationBase),(unsigned long long)exception->ContextRecord->Rcx,(unsigned long long)exception->ContextRecord->Rdx,(unsigned long long)exception->ContextRecord->R8,(unsigned long long)exception->ContextRecord->R9);fclose(file);
        }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void json_text(FILE *file,const WCHAR *value,int length)
{
    int size=WideCharToMultiByte(CP_UTF8,0,value,length,NULL,0,NULL,NULL);
    char *utf8=malloc((size_t)size+1);if(!utf8){fputs("\"\"",file);return;}
    WideCharToMultiByte(CP_UTF8,0,value,length,utf8,size,NULL,NULL);fputc('"',file);
    for(int i=0;i<size;i++) {
        unsigned char ch=(unsigned char)utf8[i];
        if(ch=='"' || ch=='\\'){fputc('\\',file);fputc(ch,file);}
        else if(ch<32)fprintf(file,"\\u%04x",ch);
        else fputc(ch,file);
    }
    fputc('"',file);free(utf8);
}

static void json_qstring(FILE *file,void (*get)(const void *,void *),const void *object)
{
    void *value=NULL;get(object,&value);
    json_text(file,qt_string_utf16(&value),qt_string_size(&value));string_destruct(&value);
}

static BOOL initialize_controls(void)
{
    if(qt_click)return TRUE;
    AddVectoredExceptionHandler(1,control_exception);
    if(!initialize_input())return FALSE;
    HMODULE core=GetModuleHandleW(L"Qt5Core.dll"),gui=GetModuleHandleW(L"Qt5Gui.dll"),widgets=GetModuleHandleW(L"Qt5Widgets.dll");
    qt_object_name=(void *)GetProcAddress(core,"?objectName@QObject@@QEBA?AVQString@@XZ");
    qt_widget_style=(void *)GetProcAddress(widgets,"?styleSheet@QWidget@@QEBA?AVQString@@XZ");
    qt_string_utf16=(void *)GetProcAddress(core,"?utf16@QString@@QEBAPEBGXZ");
    qt_string_size=(void *)GetProcAddress(core,"?size@QString@@QEBAHXZ");
    qt_ancestor=(void *)GetProcAddress(widgets,"?isAncestorOf@QWidget@@QEBA_NPEBV1@@Z");
    qt_enabled=(void *)GetProcAddress(widgets,"?isEnabled@QWidget@@QEBA_NXZ");
    qt_attribute=(void *)GetProcAddress(widgets,"?testAttribute@QWidget@@QEBA_NW4WidgetAttribute@Qt@@@Z");
    qt_parent=(void *)GetProcAddress(widgets,"?parentWidget@QWidget@@QEBAPEAV1@XZ");
    qt_button_text=(void *)GetProcAddress(widgets,"?text@QAbstractButton@@QEBA?AVQString@@XZ");
    qt_line_text=(void *)GetProcAddress(widgets,"?text@QLineEdit@@QEBA?AVQString@@XZ");
    qt_placeholder=(void *)GetProcAddress(widgets,"?placeholderText@QLineEdit@@QEBA?AVQString@@XZ");
    qt_label_text=(void *)GetProcAddress(widgets,"?text@QLabel@@QEBA?AVQString@@XZ");
    qt_html=(void *)GetProcAddress(widgets,"?toHtml@QTextEdit@@QEBA?AVQString@@XZ");
    qt_echo=(void *)GetProcAddress(widgets,"?echoMode@QLineEdit@@QEBA?AW4EchoMode@1@XZ");
    qt_max_length=(void *)GetProcAddress(widgets,"?maxLength@QLineEdit@@QEBAHXZ");
    qt_alignment=(void *)GetProcAddress(widgets,"?alignment@QLabel@@QEBA?AV?$QFlags@W4AlignmentFlag@Qt@@@@XZ");
    qt_checked=(void *)GetProcAddress(widgets,"?isChecked@QAbstractButton@@QEBA_NXZ");
    qt_set_text=(void *)GetProcAddress(widgets,"?setText@QLineEdit@@QEAAXAEBVQString@@@Z");
    qt_link=(void *)GetProcAddress(widgets,"?linkActivated@QLabel@@QEAAXAEBVQString@@@Z");
    qt_font=(void *)GetProcAddress(widgets,"?font@QWidget@@QEBAAEBVQFont@@XZ");
    qt_font_family=(void *)GetProcAddress(gui,"?family@QFont@@QEBA?AVQString@@XZ");
    qt_font_pixels=(void *)GetProcAddress(gui,"?pixelSize@QFont@@QEBAHXZ");
    qt_font_points=(void *)GetProcAddress(gui,"?pointSizeF@QFont@@QEBANXZ");
    qt_font_bold=(void *)GetProcAddress(gui,"?bold@QFont@@QEBA_NXZ");
    qt_label_pixmap=(void *)GetProcAddress(widgets,"?pixmap@QLabel@@QEBAPEBVQPixmap@@XZ");
    qt_label_size_hint=(void *)GetProcAddress(widgets,"?sizeHint@QLabel@@UEBA?AVQSize@@XZ");
    qt_pixmap_null=(void *)GetProcAddress(gui,"?isNull@QPixmap@@QEBA_NXZ");
    qt_pixmap_save=(void *)GetProcAddress(gui,"?save@QPixmap@@QEBA_NAEBVQString@@PEBDH@Z");
    qt_pixmap_key=(void *)GetProcAddress(gui,"?cacheKey@QPixmap@@QEBA_JXZ");
    qt_resource_construct=(void *)GetProcAddress(core,"??0QResource@@QEAA@AEBVQString@@AEBVQLocale@@@Z");
    qt_resource_destruct=(void *)GetProcAddress(core,"??1QResource@@QEAA@XZ");
    qt_resource_children=(void *)GetProcAddress(core,"?children@QResource@@IEBA?AVQStringList@@XZ");
    qt_resource_bytes=(void *)GetProcAddress(core,"?uncompressedData@QResource@@QEBA?AVQByteArray@@XZ");
    qt_resource_dir=(void *)GetProcAddress(core,"?isDir@QResource@@IEBA_NXZ");
    qt_locale_construct=(void *)GetProcAddress(core,"??0QLocale@@QEAA@XZ");
    qt_locale_destruct=(void *)GetProcAddress(core,"??1QLocale@@QEAA@XZ");
    qt_bytes_destruct=(void *)GetProcAddress(core,"??1QByteArray@@QEAA@XZ");
    qt_bytes_size=(void *)GetProcAddress(core,"?size@QByteArray@@QEBAHXZ");
    qt_bytes_data=(void *)GetProcAddress(core,"?constData@QByteArray@@QEBAPEBDXZ");
    qt_url_construct=(void *)GetProcAddress(core,"??0QUrl@@QEAA@AEBVQString@@W4ParsingMode@0@@@Z");
    qt_url_destruct=(void *)GetProcAddress(core,"??1QUrl@@QEAA@XZ");
    qt_anchor=(void *)GetProcAddress(widgets,"?anchorClicked@QTextBrowser@@QEAAXAEBVQUrl@@@Z");
    qt_scrollbar=(void *)GetProcAddress(widgets,"?verticalScrollBar@QAbstractScrollArea@@QEBAPEAVQScrollBar@@XZ");
    qt_slider_max=(void *)GetProcAddress(widgets,"?maximum@QAbstractSlider@@QEBAHXZ");
    qt_slider_value=(void *)GetProcAddress(widgets,"?setValue@QAbstractSlider@@QEAAXH@Z");
    qt_class_name=(void *)GetProcAddress(core,"?className@QMetaObject@@QEBAPEBDXZ");
    void *click=(void *)GetProcAddress(widgets,"?click@QAbstractButton@@QEAAXXZ");
    if(!qt_object_name || !qt_widget_style || !qt_string_utf16 || !qt_string_size || !qt_ancestor || !qt_enabled || !qt_parent || !click)return FALSE;
    qt_click=click;return TRUE;
}

static void extract_resource(const WCHAR *path,FILE *index,int depth)
{
    if(depth>16)return;
    void *string=NULL,*locale=NULL,*resource=NULL;
    string_construct(&string,path,(int)wcslen(path));qt_locale_construct(&locale);
    qt_resource_construct(&resource,&string,&locale);
    if(qt_resource_dir(&resource)) {
        QtWidgetList names={0};qt_resource_children(&resource,&names);
        if(names.data && names.data->begin>=0 && names.data->end<=names.data->allocation) {
            for(int i=names.data->begin;i<names.data->end;i++) {
                WCHAR child[32768];swprintf(child,32768,L"%ls%ls%.*ls",path,path[wcslen(path)-1]==L'/'?L"":L"/",qt_string_size(&names.data->items[i]),qt_string_utf16(&names.data->items[i]));
                extract_resource(child,index,depth+1);
            }
            if(names.data->references!=-1 && (!names.data->references || InterlockedDecrement(&names.data->references)==0)) {
                for(int i=names.data->begin;i<names.data->end;i++)string_destruct(&names.data->items[i]);
                dispose_list(names.data);
            }
        }
    } else {
        const WCHAR *extension=wcsrchr(path,L'.');
        if(extension && (!wcsicmp(extension,L".png") || !wcsicmp(extension,L".jpg") || !wcsicmp(extension,L".svg") || !wcsicmp(extension,L".qss") || !wcsicmp(extension,L".ttf") || !wcsicmp(extension,L".otf"))) {
            WCHAR filename[32768],destination[32768];wcscpy(filename,path);
            for(WCHAR *p=filename;*p;p++)if(wcschr(L":/\\*?\"<>|",*p))*p=L'_';
            swprintf(destination,32768,L"C:\\FineWine\\native-assets\\%ls",filename);
            void *bytes=NULL;qt_resource_bytes(&resource,&bytes);
            int count=qt_bytes_size(&bytes);
            if(count>0 && count<64*1024*1024) {
                FILE *file=_wfopen(destination,L"wb");if(file){fwrite(qt_bytes_data(&bytes),1,(size_t)count,file);fclose(file);}
                fputs("{\"resource\":",index);json_text(index,path,(int)wcslen(path));fputs(",\"file\":",index);json_text(index,filename,(int)wcslen(filename));fputs("},\n",index);
            }
            qt_bytes_destruct(&bytes);
        }
    }
    qt_resource_destruct(&resource);qt_locale_destruct(&locale);string_destruct(&string);
}

static NativeControl *control_for(void *widget)
{
    for(size_t i=0;i<control_count;i++)if(controls[i].widget==widget && controls[i].generation==(uint32_t)native_generation)return &controls[i];
    if(control_count>=2048)control_count=0;
    NativeControl *control=&controls[control_count++];
    *control=(NativeControl){++control_serial,(uint32_t)native_generation,widget,0};return control;
}

typedef struct {RECT window,client;LONG64 area;} GameClientGeometry;
static BOOL CALLBACK measure_game_client(HWND window,LPARAM argument)
{
    DWORD pid;GetWindowThreadProcessId(window,&pid);
    if(pid!=game_pid || !IsWindowVisible(window))return TRUE;
    WCHAR name[128];GetClassNameW(window,name,128);
    if(wcscmp(name,L"UnityWndClass"))return TRUE;
    RECT outer,client;POINT origin={0,0};
    if(!GetWindowRect(window,&outer) || !GetClientRect(window,&client) || !ClientToScreen(window,&origin))return TRUE;
    LONG64 area=(LONG64)(outer.right-outer.left)*(outer.bottom-outer.top);
    GameClientGeometry *geometry=(void *)argument;
    if(area>geometry->area){geometry->area=area;geometry->window=outer;OffsetRect(&client,origin.x,origin.y);geometry->client=client;}
    return TRUE;
}

static void publish_native_controls(void)
{
    static ULONGLONG previous;static BOOL extracted;
    if(!native_mode || !sdk_widget || !initialize_controls() || GetTickCount64()-previous<100)return;
    previous=GetTickCount64();
    CreateDirectoryW(L"C:\\FineWine\\native-assets",NULL);
    if(GetFileAttributesW(L"C:\\FineWine\\native-assets\\index.json")!=INVALID_FILE_ATTRIBUTES)extracted=TRUE;
    if(!extracted && qt_resource_construct && qt_resource_bytes) {
        FILE *index=_wfopen(L"C:\\FineWine\\native-assets\\index.json",L"w");
        if(index){fputs("[\n",index);extract_resource(L":/",index,0);fputs("{}]\n",index);fclose(index);extracted=TRUE;}
    }
    FILE *file=_wfopen(L"C:\\FineWine\\native-widgets.stage",L"w+b");if(!file)return;
    setvbuf(file,NULL,_IONBF,0);
    fprintf(file,"{\"generation\":%ld,\"phase\":%lu,\"width\":%d,\"height\":%d,\"root\":%u",native_generation,native_phase,widget_width(sdk_widget),widget_height(sdk_widget),control_for(sdk_widget)->id);
    GameClientGeometry geometry={0};EnumWindows(measure_game_client,(LPARAM)&geometry);
    double game_width=geometry.window.right-geometry.window.left,game_height=geometry.window.bottom-geometry.window.top;
    if(game_width>0 && game_height>0)fprintf(file,",\"clientArea\":{\"x\":%.8f,\"y\":%.8f,\"width\":%.8f,\"height\":%.8f}",(geometry.client.left-geometry.window.left)/game_width,(geometry.client.top-geometry.window.top)/game_height,(geometry.client.right-geometry.client.left)/game_width,(geometry.client.bottom-geometry.client.top)/game_height);
    fputs(",\"nodes\":[",file);
    QtWidgetList list={0};all_widgets(&list);BOOL comma=FALSE;
    BYTE *values=NULL;DWORD values_bytes=0;
    BYTE *visual_pixels=NULL;DWORD visual_bytes=0,visual_width=0,visual_height=0,visual_id=0;
    if(list.data && list.data->begin>=0 && list.data->end<=list.data->allocation)for(int i=list.data->begin;i<list.data->end;i++) {
        void *widget=list.data->items[i];
        if(!widget || !widget_visible(widget,NULL) || (widget!=sdk_widget && !qt_ancestor(sdk_widget,widget)))continue;
        int width=widget_width(widget),height=widget_height(widget);if(width<=0 || height<=0)continue;
        NativeControl *control=control_for(widget);QtPoint zero={0,0},position;
        widget_map_from(widget,&position,sdk_widget,&zero);position.x=-position.x;position.y=-position.y;
        const char *kind="view";
        if(object_inherits(widget,"QLineEdit"))kind="input";
        else if(object_inherits(widget,"QTextEdit"))kind="document";
        else if(object_inherits(widget,"QAbstractButton"))kind=(object_inherits(widget,"QCheckBox") || object_inherits(widget,"QRadioButton"))?"check":"button";
        else if(object_inherits(widget,"QLabel"))kind="label";
        if(comma)fputc(',',file);comma=TRUE;
        fprintf(file,"{\"id\":%u,\"parent\":%u,\"kind\":\"%s\",\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,\"enabled\":%s,\"name\":",control->id,widget==sdk_widget?0:control_for(qt_parent(widget))->id,kind,position.x,position.y,width,height,qt_enabled(widget)?"true":"false");
        json_qstring(file,qt_object_name,widget);fputs(",\"style\":",file);json_qstring(file,qt_widget_style,widget);
        if(qt_class_name){const void *(*meta)(const void *)=(void *)(*(void ***)widget)[0];fprintf(file,",\"type\":\"%s\"",qt_class_name(meta(widget)));}
        if(object_inherits(widget,"mj_official_cn::ExtendedQrCodeWidget")) {
            fputs(",\"visual\":true",file);
            int size=meta_size(meta_type("QImage"));void *render=calloc(1,(size_t)size);
            if(render) {
                image_construct(render,width*3,height*3,5);image_ratio(render,3.0);image_fill(render,0xffffffff);
                widget_render(widget,render,origin,region,3);
                int stride=image_bytes_per_line(render);
                if(stride==width*12) {
                    free(visual_pixels);visual_bytes=(DWORD)stride*(DWORD)height*3;
                    visual_pixels=malloc(visual_bytes);
                    if(visual_pixels){memcpy(visual_pixels,image_data(render),visual_bytes);visual_width=(DWORD)width*3;visual_height=(DWORD)height*3;visual_id=control->id;}
                }
                image_destruct(render);free(render);
            }
        }
        const void *font=qt_font(widget);fputs(",\"font\":",file);json_qstring(file,qt_font_family,font);
        int pixels=qt_font_pixels(font);fprintf(file,",\"fontSize\":%.2f,\"bold\":%s",pixels>0?(double)pixels:qt_font_points(font)*96.0/72.0,qt_font_bold(font)?"true":"false");
        if(!strcmp(kind,"button") || !strcmp(kind,"check")){fputs(",\"text\":",file);json_qstring(file,qt_button_text,widget);fprintf(file,",\"checked\":%s",qt_checked(widget)?"true":"false");}
        if(!strcmp(kind,"input")){
            fprintf(file,",\"secure\":%s,\"maxLength\":%d,\"placeholder\":",qt_echo(widget)?"true":"false",qt_max_length(widget));json_qstring(file,qt_placeholder,widget);
            void *value=NULL;qt_line_text(widget,&value);int chars=qt_string_size(&value);
            if(chars>=0 && chars<=16384 && values_bytes+(DWORD)chars*2+8<=1024*1024) {
                DWORD bytes=8+(DWORD)chars*2;BYTE *grown=realloc(values,values_bytes+bytes);
                if(grown){values=grown;uint32_t header[]={control->id,(uint32_t)chars};memcpy(values+values_bytes,header,8);memcpy(values+values_bytes+8,qt_string_utf16(&value),(size_t)chars*2);values_bytes+=bytes;}
            }
            string_destruct(&value);
        }
        if(!strcmp(kind,"label") || !strcmp(kind,"document")) {
            fputs(",\"text\":",file);json_qstring(file,!strcmp(kind,"label")?qt_label_text:qt_html,widget);
            if(!strcmp(kind,"label")) {
                int alignment=0;qt_alignment(widget,&alignment);fprintf(file,",\"alignment\":%d",alignment);
                const void *pixmap=qt_label_pixmap(widget);
                if(pixmap && !qt_pixmap_null(pixmap)) {
                    unsigned long long key=(unsigned long long)qt_pixmap_key(pixmap);WCHAR filename[128],path[256];
                    swprintf(filename,128,L"pixmap-%llx.png",key);swprintf(path,256,L"C:\\FineWine\\native-assets\\%ls",filename);
                    if(key!=control->image_key){void *destination=NULL;string_construct(&destination,path,(int)wcslen(path));qt_pixmap_save(pixmap,&destination,"PNG",-1);string_destruct(&destination);control->image_key=key;}
                    fputs(",\"image\":",file);json_text(file,filename,(int)wcslen(filename));
                }
            }
        }
        fputc('}',file);
    }
    fputs("],\"toast\":",file);
    void *toast=NULL,*label=NULL;
    if(list.data && list.data->begin>=0 && list.data->end<=list.data->allocation) {
        for(int i=list.data->begin;i<list.data->end;i++) {
            void *candidate=list.data->items[i];
            if(candidate && widget_visible(candidate,NULL) && object_inherits(candidate,"mj_base::MjToastWnd")){toast=candidate;break;}
        }
        if(toast) {
            if(widget_opacity)widget_opacity(toast,0.0);
            for(int i=list.data->begin;i<list.data->end;i++) {
                void *candidate=list.data->items[i];
                if(candidate && widget_visible(candidate,NULL) && object_inherits(candidate,"QLabel") && qt_ancestor(toast,candidate)){label=candidate;break;}
            }
        }
    }
    if(toast && label) {
        const void *font=qt_font(label);int pixels=qt_font_pixels(font);
        QtSize preferred={widget_width(label),widget_height(label)};
        if(qt_label_size_hint){QtSize hint={0};qt_label_size_hint(label,&hint);if(hint.width>0 && hint.height>0)preferred=hint;}
        int layout[]={widget_width(toast),widget_height(toast),widget_width(label),widget_height(label),preferred.width,preferred.height};
        static int previous_layout[6];
        if(memcmp(previous_layout,layout,sizeof(layout))) {
            memcpy(previous_layout,layout,sizeof(layout));FILE *layout_file=_wfopen(L"C:\\FineWine\\toast-layout.json",L"w");
            if(layout_file){fprintf(layout_file,"{\"rootWidth\":%d,\"rootHeight\":%d,\"labelWidth\":%d,\"labelHeight\":%d,\"preferredWidth\":%d,\"preferredHeight\":%d}\n",layout[0],layout[1],layout[2],layout[3],layout[4],layout[5]);fclose(layout_file);}
        }
        fprintf(file,"{\"width\":%d,\"height\":%d,\"rootWidth\":%d,\"rootHeight\":%d,\"labelWidth\":%d,\"labelHeight\":%d,\"fontSize\":%.2f,\"font\":",preferred.width,preferred.height,widget_width(toast),widget_height(toast),widget_width(label),widget_height(label),pixels>0?(double)pixels:qt_font_points(font)*96.0/72.0);
        json_qstring(file,qt_font_family,font);fputs(",\"text\":",file);json_qstring(file,qt_label_text,label);fputs(",\"style\":",file);json_qstring(file,qt_widget_style,toast);fputc('}',file);
    } else fputs("null",file);
    if(list.data && list.data->references!=-1 && (!list.data->references || InterlockedDecrement(&list.data->references)==0))dispose_list(list.data);
    fputc('}',file);long bytes=ftell(file);rewind(file);
    char *json=malloc((size_t)bytes+1);if(json){fread(json,1,(size_t)bytes,file);json[bytes]=0;
        EnterCriticalSection(&native_frame_lock);free(native_json);native_json=json;native_json_bytes=(DWORD)bytes;native_json_sequence++;
        if(native_values){SecureZeroMemory(native_values,native_values_bytes);free(native_values);}native_values=values;native_values_bytes=values_bytes;values=NULL;
        if(native_visual_pixels){SecureZeroMemory(native_visual_pixels,native_visual_bytes);free(native_visual_pixels);}native_visual_pixels=visual_pixels;native_visual_bytes=visual_bytes;native_visual_width=visual_width;native_visual_height=visual_height;native_visual_id=visual_id;visual_pixels=NULL;
        LeaveCriticalSection(&native_frame_lock);
        InterlockedExchange(&native_visible,1);
    }
    if(values){SecureZeroMemory(values,values_bytes);free(values);}
    if(visual_pixels){SecureZeroMemory(visual_pixels,visual_bytes);free(visual_pixels);}
    fclose(file);DeleteFileW(L"C:\\FineWine\\native-widgets.stage");
}

static void handle_control_action(NativeInput *input)
{
    if(!initialize_controls())return;
    NativeControl *control=NULL;
    for(size_t i=0;i<control_count;i++)if(controls[i].id==input->key && controls[i].generation==(uint32_t)native_generation){control=&controls[i];break;}
    if(!control || !live_widget(control->widget)) {
        if(diagnostic){fprintf(diagnostic,"native action rejected: id=%u action=%d generation=%u current=%ld\n",input->key,input->x,input->generation,native_generation);fflush(diagnostic);}
        return;
    }
    void *widget=control->widget;
    if(!widget_visible(widget,NULL) || (widget!=sdk_widget && !qt_ancestor(sdk_widget,widget)))return;
    if(input->x==1 && (object_inherits(widget,"QAbstractButton") || object_inherits(widget,"mj_official_cn::UserCenterBtn") || object_inherits(widget,"mj_official_cn::LicenseAgreementBtn"))){
        if(diagnostic){fprintf(diagnostic,"native button activated: id=%u generation=%u\n",input->key,input->generation);fflush(diagnostic);}
        while(qt_attribute && qt_attribute(widget,51) && qt_parent(widget))widget=qt_parent(widget);
        QtPoint local={widget_width(widget)/2,widget_height(widget)/2},position,global;
        widget_map_to(widget,&position,sdk_widget,&local);widget_map_global(widget,&global,&local);
        QtPointF local_f={local.x,local.y},window_f={position.x,position.y},global_f={global.x,global.y};
        _Alignas(16) BYTE event[104];
        mouse_construct(event,2,&local_f,&window_f,&global_f,1,1,0);qt_send_event(widget,event);mouse_destruct(event);
        if(live_widget(widget)) {
            mouse_construct(event,3,&local_f,&window_f,&global_f,1,0,0);qt_send_event(widget,event);mouse_destruct(event);
        }
        return;
    }
    void *text=NULL;string_construct(&text,input->text,(int)input->chars);
    if(input->x==2 && object_inherits(widget,"QLineEdit"))qt_set_text(widget,&text);
    if(input->x==3) {
        if(object_inherits(widget,"QTextBrowser")) {
            int size=meta_size(meta_type("QUrl"));void *url=calloc(1,(size_t)size);
            if(url){qt_url_construct(url,&text,0);qt_anchor(widget,url);qt_url_destruct(url);free(url);}
        } else if(object_inherits(widget,"QLabel"))qt_link(widget,&text);
    }
    if(input->x==4 && object_inherits(widget,"QAbstractScrollArea")) {
        void *bar=qt_scrollbar(widget);int maximum=qt_slider_max(bar);qt_slider_value(bar,MulDiv(input->y,maximum,10000));
    }
    string_destruct(&text);
}
