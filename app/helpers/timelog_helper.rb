#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2014 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

module TimelogHelper
  include ApplicationHelper
  include WorkPackage::CsvExporter

  def render_timelog_breadcrumb
    links = []
    links << link_to(l(:label_project_all), {:project_id => nil, :work_package_id => nil})
    links << link_to(h(@project), {:project_id => @project, :work_package_id => nil}) if @project
    if @issue
      if @issue.visible?
        links << link_to_work_package(@issue, :subject => false)
      else
        links << "##{@issue.id}".html_safe
      end
    end
    breadcrumb links
  end

  # Returns a collection of activities for a select field.  time_entry
  # is optional and will be used to check if the selected TimeEntryActivity
  # is active.
  def activity_collection_for_select_options(time_entry=nil, project=nil)
    project ||= @project
    if project.nil?
      activities = TimeEntryActivity.shared.active
    else
      activities = project.activities
    end

    collection = []
    if time_entry && time_entry.activity && !time_entry.activity.active?
      collection << [ "--- #{l(:actionview_instancetag_blank_option)} ---", '' ]
    else
      collection << [ "--- #{l(:actionview_instancetag_blank_option)} ---", '' ] unless activities.detect(&:is_default)
    end
    activities.each { |a| collection << [a.name, a.id] }
    collection
  end

  def select_hours(data, criteria, value)
    if value.to_s.empty?
      data.select {|row| row[criteria].blank? }
    else
      data.select {|row| row[criteria].to_s == value.to_s}
    end
  end

  def sum_hours(data)
    sum = 0
    data.each do |row|
      sum += row['hours'].to_f
    end
    sum
  end

  def options_for_period_select(value)
    options_for_select([[l(:label_all_time), 'all'],
                        [l(:label_today), 'today'],
                        [l(:label_yesterday), 'yesterday'],
                        [l(:label_this_week), 'current_week'],
                        [l(:label_last_week), 'last_week'],
                        [l(:label_last_n_days, 7), '7_days'],
                        [l(:label_this_month), 'current_month'],
                        [l(:label_last_month), 'last_month'],
                        [l(:label_last_n_days, 30), '30_days'],
                        [l(:label_this_year), 'current_year']],
                        value)
  end

  def entries_to_csv(entries)
    decimal_separator = l(:general_csv_decimal_separator)
    custom_fields = TimeEntryCustomField.find(:all)
    export = CSV.generate(:col_sep => l(:general_csv_separator)) do |csv|
      # csv header fields
      headers = [TimeEntry.human_attribute_name(:spent_on),
                 TimeEntry.human_attribute_name(:user),
                 TimeEntry.human_attribute_name(:activity),
                 TimeEntry.human_attribute_name(:project),
                 TimeEntry.human_attribute_name(:issue),
                 TimeEntry.human_attribute_name(:type),
                 TimeEntry.human_attribute_name(:subject),
                 TimeEntry.human_attribute_name(:hours),
                 TimeEntry.human_attribute_name(:comments)
                 ]
      # Export custom fields
      headers += custom_fields.collect(&:name)

      csv << encode_csv_columns(headers)
      # csv lines
      entries.each do |entry|
        fields = [format_date(entry.spent_on),
                  entry.user,
                  entry.activity,
                  entry.project,
                  (entry.work_package ? entry.work_package.id : nil),
                  (entry.work_package ? entry.work_package.type : nil),
                  (entry.work_package ? entry.work_package.subject : nil),
                  entry.hours.to_s.gsub('.', decimal_separator),
                  entry.comments
                  ]
        fields += custom_fields.collect {|f| show_value(entry.custom_value_for(f)) }

        csv << encode_csv_columns(fields)
      end
    end
    export
  end

  def format_criteria_value(criteria, value)
    if value.blank?
      l(:label_none)
    elsif k = @available_criterias[criteria][:klass]
      obj = k.find_by_id(value.to_i)
      if obj.is_a?(WorkPackage)
        obj.visible? ? h("#{obj.type} ##{obj.id}: #{obj.subject}") : h("##{obj.id}")
      else
        obj
      end
    else
      format_value(value, @available_criterias[criteria][:format])
    end
  end

  def report_to_csv(criterias, periods, hours)
    export = CSV.generate(:col_sep => l(:general_csv_separator)) do |csv|
      # Column headers
      headers = criterias.collect do |criteria|
        label = @available_criterias[criteria][:label]
        label.is_a?(Symbol) ? l(label) : label
      end
      headers += periods
      headers << l(:label_total)
      csv << headers.collect {|c| to_utf8_for_timelogs(c) }
      # Content
      report_criteria_to_csv(csv, criterias, periods, hours)
      # Total row
      row = [ l(:label_total) ] + [''] * (criterias.size - 1)
      total = 0
      periods.each do |period|
        sum = sum_hours(select_hours(hours, @columns, period.to_s))
        total += sum
        row << (sum > 0 ? "%.2f" % sum : '')
      end
      row << "%.2f" %total
      csv << row
    end
    export
  end

  def report_criteria_to_csv(csv, criterias, periods, hours, level=0)
    hours.collect {|h| h[criterias[level]].to_s}.uniq.each do |value|
      hours_for_value = select_hours(hours, criterias[level], value)
      next if hours_for_value.empty?
      row = [''] * level
      row << to_utf8_for_timelogs(format_criteria_value(criterias[level], value))
      row += [''] * (criterias.length - level - 1)
      total = 0
      periods.each do |period|
        sum = sum_hours(select_hours(hours_for_value, @columns, period.to_s))
        total += sum
        row << (sum > 0 ? "%.2f" % sum : '')
      end
      row << "%.2f" %total
      csv << row

      if criterias.length > level + 1
        report_criteria_to_csv(csv, criterias, periods, hours_for_value, level + 1)
      end
    end
  end

  def to_utf8_for_timelogs(s)
    begin; s.to_s.encode(l(:general_csv_encoding), 'UTF-8'); rescue; s.to_s; end
  end

  def polymorphic_time_entries_path(object)
    polymorphic_path([object, :time_entries])
  end

  def polymorphic_new_time_entry_path(object)
    polymorphic_path([:new, object, :time_entry,])
  end

  def polymorphic_time_entries_report_path(object)
    polymorphic_path([object, :time_entries, :report])
  end

  # Retrieves the date range based on predefined ranges or specific from/to param dates
  def retrieve_date_range
    @free_period = false
    @from, @to = nil, nil

    if params[:period_type] == '1' || (params[:period_type].nil? && !params[:period].nil?)
      case params[:period].to_s
      when 'today'
        @from = @to = Date.today
      when 'yesterday'
        @from = @to = Date.today - 1
      when 'current_week'
        @from = Date.today - (Date.today.cwday - 1)%7
        @to = @from + 6
      when 'last_week'
        @from = Date.today - 7 - (Date.today.cwday - 1)%7
        @to = @from + 6
      when '7_days'
        @from = Date.today - 7
        @to = Date.today
      when 'current_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1)
        @to = (@from >> 1) - 1
      when 'last_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1) << 1
        @to = (@from >> 1) - 1
      when '30_days'
        @from = Date.today - 30
        @to = Date.today
      when 'current_year'
        @from = Date.civil(Date.today.year, 1, 1)
        @to = Date.civil(Date.today.year, 12, 31)
      end
    elsif params[:period_type] == '2' || (params[:period_type].nil? && (!params[:from].nil? || !params[:to].nil?))
      begin; @from = params[:from].to_s.to_date unless params[:from].blank?; rescue; end
      begin; @to = params[:to].to_s.to_date unless params[:to].blank?; rescue; end
      @free_period = true
    else
      # default
    end

    @from, @to = @to, @from if @from && @to && @from > @to
    @from ||= (TimeEntry.earliest_date_for_project(@project) || Date.today)
    @to   ||= (TimeEntry.latest_date_for_project(@project) || Date.today)
  end

  def find_optional_project
    if !params[:issue_id].blank?
      @issue = WorkPackage.find(params[:issue_id])
      @project = @issue.project
    elsif !params[:work_package_id].blank?
      @issue = WorkPackage.find(params[:work_package_id])
      @project = @issue.project
    elsif !params[:project_id].blank?
      @project = Project.find(params[:project_id])
    end
    deny_access unless User.current.allowed_to?(:view_time_entries, @project, :global => true)
  end
  ## start Team Member Time Sheet
  def format_criteria_value_username(criteria, value)
    if value.blank?
      l(:label_none)
    elsif k = @available_criterias[criteria][:klass]
      obj = k.find_by_id(value.to_i)
      if obj.is_a?(WorkPackage)
        obj.visible? ? h("#{obj.type} ##{obj.id}: #{obj.subject}") : h("##{obj.id}")
      elsif criteria == "member"
        arry_obj = nil
        arry_obj = h(format_criteria_value(criteria, value))
        arry_obj
      else
        obj
      end
    else
      format_value(value, @available_criterias[criteria][:format])
    end
  end
  def format_criteria_value_empid(criteria, value)
    if value.blank?
      l(:label_none)
    elsif k = @available_criterias[criteria][:klass]
      obj = k.find_by_id(value.to_i)
      if obj.is_a?(WorkPackage)
        obj.visible? ? h("#{obj.type} ##{obj.id}: #{obj.subject}") : h("##{obj.id}")
      elsif criteria == "member"
        arry_obj,c = nil,nil
        emp_id = CustomValue.where(:customized_id => obj.id ,:custom_field_id => 28).last
        arry_obj = c if c = emp_id.blank? ?  "" : emp_id.value
        arry_obj
      else
        obj
      end
    else
      format_value(value, @available_criterias[criteria][:format])
    end
  end
  def format_criteria_value_repmgr(criteria, value)
    if value.blank?
      l(:label_none)
    elsif k = @available_criterias[criteria][:klass]
      obj = k.find_by_id(value.to_i)
      if obj.is_a?(WorkPackage)
        obj.visible? ? h("#{obj.type} ##{obj.id}: #{obj.subject}") : h("##{obj.id}")
      elsif criteria == "member"
        arry_obj,r = nil,nil
        rep_mgr = CustomValue.where(:customized_id => obj.id ,:custom_field_id => 27).last
        arry_obj = r  if r = rep_mgr.blank? ?  "" : rep_mgr.value
        arry_obj
      else
        obj
      end
    else
      format_value(value, @available_criterias[criteria][:format])
    end
  end
  def format_criteria_value_team(criteria, value)
    if value.blank?
      l(:label_none)
    elsif k = @available_criterias[criteria][:klass]
      obj = k.find_by_id(value.to_i)
      if obj.is_a?(WorkPackage)
        obj.visible? ? h("#{obj.type} ##{obj.id}: #{obj.subject}") : h("##{obj.id}")
      elsif criteria == "member"
        arry_obj,t = nil,nil
        team = CustomValue.where(:customized_id => obj.id ,:custom_field_id => 29).last
        arry_obj = t  if t = team.blank? ?  "" : team.value
        arry_obj
      else
        obj
      end
    else
      format_value(value, @available_criterias[criteria][:format])
    end
  end
  def spent_report_to_csv(criterias, periods, hours)
    export = CSV.generate(:col_sep => l(:general_csv_separator)) do |csv|
      # Column headers
      headers = criterias.collect do |criteria|
        label = @available_criterias[criteria][:label]
        label.is_a?(Symbol) ? l(label) : label
      end
      if headers.include? "UserName,EmpID,RepMgr,Team"
        headers.map! { |e| e == "UserName,EmpID,RepMgr,Team" ? ["User Name","Emp ID","Reporting Manager","Team"] : e }.flatten!
      end
      headers += periods
      headers << l(:label_total)
      csv << headers.collect {|c| to_utf8_for_timelogs(c) }
      # Content
      spent_report_criteria_to_csv(csv, criterias, periods, hours)
      # Total row
      if criterias.include? "member"
        row = [ l(:label_total) ] + [''] * ((criterias.size + 3) - 1)
      else
        row = [ l(:label_total) ] + [''] * (criterias.size - 1)
      end
      total = 0
      periods.each do |period|
        sum = sum_hours(select_hours(hours, @columns, period.to_s))
        total += sum
        row << (sum > 0 ? "%.2f" % sum : '')
      end
      row << "%.2f" %total
      csv << row
    end
    export
  end
  def spent_report_criteria_to_csv(csv, criterias, periods, hours, level=0)
    hours.collect {|h| h[criterias[level]].to_s}.uniq.each do |value|
      hours_for_value = select_hours(hours, criterias[level], value)
      next if hours_for_value.empty?
      row = [''] * level
      if criterias[level] == "member"
        row << to_utf8_for_timelogs(format_criteria_value_username(criterias[level], value))
        row << to_utf8_for_timelogs(format_criteria_value_empid(criterias[level], value))
        row << to_utf8_for_timelogs(format_criteria_value_repmgr(criterias[level], value))
        row << to_utf8_for_timelogs(format_criteria_value_team(criterias[level], value))
      else
        row << to_utf8_for_timelogs(format_criteria_value(criterias[level], value))
      end
      row += [''] * (criterias.length - level - 1)
      total = 0
      periods.each do |period|
        sum = sum_hours(select_hours(hours_for_value, @columns, period.to_s))
        total += sum
        row << (sum > 0 ? "%.2f" % sum : '')
      end
      row << "%.2f" %total
      csv << row

      if criterias.length > level + 1
        report_criteria_to_csv(csv, criterias, periods, hours_for_value, level + 1)
      end
    end
  end
  def render_menu_report(menu, project=nil)
    links = []
    links << ["<li><a href=\"/reports/show\" class=\"icon2 icon-list-view2 overview ellipsis\" title=\"Team Member Time Sheet\">Team Member Time Sheet</a></li>",
              "<li><a href=\"/reports/report_view\" class=\"icon2 icon-list-view2 overview ellipsis\" title=\"Non Active Status\">Non Active Status</a></li>",
              "<li><a href=\"/reports/all_open_project_users\" class=\"icon2 icon-list-view2 overview ellipsis\" title=\"All Open Project Users\">All Open Project Users</a></li>",
              "<li><a href=\"/reports/admin_tasks_due\" class=\"icon2 icon-list-view2 overview ellipsis\" title=\"Admin Tasks Due\">Admin Tasks Due</a></li>"
              ]
    links.empty? ? nil : content_tag('ul', links.join("\n").html_safe, :class => "menu_root")
  end

  def report_view_csv(user)
    export = CSV.generate(:col_sep => l(:general_csv_separator)) do |csv|
      csv <<  ["User Name","Emp ID","Reporting Manager","Team"]
      user.collect {|c|
        csv <<  [c.emp_id,c.emp_name,c.report_manager,c.team]
      }

    end
    export
  end
  def all_open_project_users_csv(user)
    export = CSV.generate(:col_sep => l(:general_csv_separator)) do |csv|
      csv <<  ["Login","First Name","Last Name","Email","Emp ID","Report Manager","Team"]
      user.collect {|c|
        csv <<  [c.login,c.firstname,c.lastname,c.mail,c.custom_field_values.select{|c| c.custom_field_id.to_s == "28"}.first.value,c.custom_field_values.select{|c| c.custom_field_id.to_s == "27"}.first.value,c.custom_field_values.select{|c| c.custom_field_id.to_s == "29"}.first.value]
      }

    end
    export
  end
  ## end  Team Member Time Sheet
end
