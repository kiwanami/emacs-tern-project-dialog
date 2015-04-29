;;; tern-project-dialog.el --- 

;; Author: SAKURAI Masashi <m.sakurai at kiwanami.net>
;; Version: 0.0.2
;; Package-Requires: ((tern "0.7.0") (widget-mvc "0.0.1"))

;;; Commentary:

;; M-x tern-prj-dialog
;; 

;;; Code:

(require 'tern)
(require 'cl-lib)
(require 'json)
(require 'widget-mvc) ; https://github.com/kiwanami/emacs-widget-mvc


(defvar tern-home
  (let* ((tern-path (if (string= "node" (car tern-command)) (cadr tern-command) (car tern-command))))
    (expand-file-name ".." (file-name-directory (file-truename tern-path))))
  "installed tern-home.")

(eval-when-compile 
  (defmacro tern-prj-collect-gen (target)
    `(cl-loop with plugins-dir = (expand-file-name ,target tern-home)
           for fn in (directory-files plugins-dir t "^[^\\.]")
           collect (list (cl-gensym ,target) 
                         (file-name-sans-extension (file-name-nondirectory fn)) 
                         fn))))

(defun tern-prj-collect-libs ()
  (tern-prj-collect-gen "defs"))

(defun tern-prj-collect-plugins ()
  (tern-prj-collect-gen "plugin"))

(defun tern-prj-find-by-name (name item-list)
  "ITEM-LIST -> (list (sym pname content) ... )"
  (unless (stringp name)
    (setq name (format "%s" name)))
  (cl-loop for item in item-list
        for pname = (cadr item)
        if (equal name pname) return item))

(defun tern-prj-collect-jsfiles (dir &optional base-dir)
  (unless base-dir
    (setq base-dir dir))
  (cl-loop 
   with ret = nil
   for fn in (directory-files dir nil "^[^\\.]")
   for path = (expand-file-name fn dir)
   if (and (file-directory-p path) (not (string-match "node_modules" path)))
   do (setq ret (append (tern-prj-collect-jsfiles path base-dir) ret))
   else
   do (when (equal "js" (file-name-extension fn))
        (let ((name (file-relative-name path base-dir)))
          (setq ret (cons (list name name) ret))))
   finally return ret))

;;;###autoload
(defun tern-prj-dialog ()
  "Find a tern project file and show the editing dialog for the project file."
  (interactive)
  (let* ((pdir (tern-project-dir))
         (pfile (expand-file-name ".tern-project" pdir))
         project-data)
    (when (file-exists-p pfile)
      (setq project-data 
            (let ((json-array-type 'list))
              (ignore-errors
                (json-read-file pfile)))))
    (tern-prj-dialog-show pdir project-data)))

(defvar tern-prj-dialog-before-win-num 0  "[internal] ")

(defun tern-prj-dialog-show (pdir project-data)
  (let* ((libs (tern-prj-collect-libs))
         (plugins (tern-prj-collect-plugins))
         (jsfiles (tern-prj-collect-jsfiles pdir))
         (src `(
               ,(propertize "JavaScript Project Setting" 'face 'info-title-1) BR
               "Project Directory : " ,pdir BR BR
               ,(propertize "Project Environments" 'face 'info-title-2) BR
               ,@(cl-loop for (sym name path) in libs
                       append (list `(input :name ,sym :type checkbox)
                                     "  " name 'BR))
               BR ,(propertize "Tern Plugins" 'face 'info-title-2) BR
               ,@(cl-loop for (sym name path) in plugins
                       append (list `(input :name ,sym :type checkbox)
                                    "  " name 'BR))
               BR ,(propertize "Load Eagerly" 'face 'info-title-2) BR
               ,@(cl-loop for (sym name path) in jsfiles
                       append (list `(input :name ,sym :type checkbox)
                                    "  " name 'BR))
               BR BR
               "  " (button :title "OK" :action on-submit :validation t)
               "  " (button :title "Cancel" :action on-cancel)))
        (model 
         (let ((data-plugins (cdr (assoc 'plugins project-data)))
               (data-libs (cdr (assoc 'libs project-data)))
               (data-jsfiles (cdr (assoc 'loadEagerly project-data))))
           (append
            (cl-loop for (sym pname content) in plugins
                  for (name . opts) = (assoc (intern pname) data-plugins)
                  collect (cons sym (and name t)))
            (cl-loop for (sym pname content) in libs
                  collect (cons sym (and (member pname data-libs) t)))
            (cl-loop for (path name) in jsfiles
                  collect (cons path (and (member path data-jsfiles) t))))))
        (validations nil)
        (action-mapping 
         '((on-submit . tern-prj-submit-action)
           (on-cancel . tern-prj-dialog-kill-buffer)))
        (attributes (list 
                     (cons 'project-dir pdir) (cons 'libs libs)
                     (cons 'jsfiles jsfiles) (cons 'plugins plugins))))
    (setq tern-prj-dialog-before-win-num (length (window-list)))
    (pop-to-buffer
     (wmvc:build-buffer 
      :buffer (wmvc:get-new-buffer)
      :tmpl src :model model :actions action-mapping
      :validations validations :attributes attributes))))

(defun tern-prj-submit-action (model)
  (let* ((ctx wmvc:context)
         (pdir (wmvc:context-attr-get ctx 'project-dir))
         (pfile (expand-file-name ".tern-project" pdir))
         (plugins (wmvc:context-attr-get ctx 'plugins))
         (libs (wmvc:context-attr-get ctx 'libs))
         (jsfiles (wmvc:context-attr-get ctx 'jsfiles))
         (coding-system-for-write 'utf-8)
         (json-object-type 'hash-table)
         after-save-hook before-save-hook
         (json (json-encode 
                (list
                 (cons 'plugins
                       (cl-loop with ps = (make-hash-table)
                             for (sym pname content) in plugins
                             for (msym . val) = (assoc sym model)
                             if val do
                             (puthash pname (make-hash-table) ps)
                             finally return ps))
                 (cons 'libs
                       (vconcat
                        (cl-loop for (sym pname content) in libs
                              for (msym . val) = (assoc sym model)
                              if val collect pname)))
                 (cons 'loadEagerly
                       (vconcat
                        (cl-loop for (path name) in jsfiles
                              for (path . val) = (assoc path model)
                              if val collect path))))))
         (buf (find-file-noselect pfile)))
    (unwind-protect
        (with-current-buffer buf
          (set-visited-file-name nil)
          (buffer-disable-undo)
          (erase-buffer)
          (insert json)
          (write-region (point-min) (point-max) pfile nil 'ok))
      (kill-buffer buf))
    (tern-prj-restart-server))
  (tern-prj-dialog-kill-buffer))

(defun tern-prj-dialog-kill-buffer (&optional model)
  (let ((cbuf (current-buffer))
        (win-num (length (window-list))))
    (when (and (not (one-window-p))
               (> win-num tern-prj-dialog-before-win-num))
      (delete-window))
    (kill-buffer cbuf)))

(defun tern-prj-restart-server ()
  (cl-loop for i in (process-list)
        if (string= (process-name i) "Tern")
        do (quit-process i)))

(provide 'tern-project-dialog)
;;; tern-project-dialog.el ends here
